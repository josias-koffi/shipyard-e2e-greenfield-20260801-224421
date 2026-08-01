#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agent-loop.sh — shipyard autonomous delivery loop (minimal, P1).
#
# Loop engineering, not "let the model decide": THIS script owns control flow.
# Each iteration takes ONE issue through a bounded pipeline with a FRESH agent
# session per step, and the merge gate is HARD signals first, agent judgement
# second (docs/PLAN.md §9).
#
#   pick todo issue → worktree+branch → DEV (Sonnet) → commit/push/PR
#   → fresh REVIEW (Opus) waits for green CI → hard-gate + approve → squash-merge
#   → issue done. Failures re-inject as context (Ralph "pressure cooker").
#   Exhausted attempts/rounds → "blocked" + phone notification (escalation).
#
# STATUS MODEL (minimal): driven by issue labels
#   status:todo → status:in-progress → status:in-review → (merged, closed) | status:blocked
# Mirroring these to a GitHub Projects v2 Status column is wired in P3
# (project-setup.sh). The loop is intentionally board-agnostic for now.
#
# Prereqs on the host: git, gh (authenticated), jq, and Claude Code (`claude`).
# Run from a repo initialised by shipyard. Drive it from your phone via Happy:
#   ./.project/loop/agent-loop.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE="$REPO_ROOT/.project/state.json"

# shellcheck source=/dev/null
source "$LOOP_DIR/claude-invoke.sh"

# ── Config (overridable via env) ─────────────────────────────────────────────
: "${SHIPYARD_BASE:=develop}"                 # integration branch
: "${SHIPYARD_TODO_LABEL:=status:todo}"
: "${SHIPYARD_WIP_LABEL:=status:in-progress}"
: "${SHIPYARD_REVIEW_LABEL:=status:in-review}"
: "${SHIPYARD_BLOCKED_LABEL:=status:blocked}"

MAX_ITERS="$(jq -r '.loop.max_iterations_per_sprint // 50' "$STATE")"
MAX_ATTEMPTS="$(jq -r '.loop.max_attempts_per_issue // 3' "$STATE")"
MAX_REVIEW="$(jq -r '.loop.max_review_rounds // 3' "$STATE")"

# Worktree parallelism (P5.3): how many issues to process concurrently. Default 1
# = fully sequential (unchanged behaviour). Each issue already lives in its own
# worktree (.worktrees/issue-<n>) + branch feat/<n>, so they don't collide; the
# shared state.json, worktree creation, and PR merges are serialized with flock.
: "${SHIPYARD_PARALLELISM:=1}"

# ── Notifications (phone alerts via the bundled notifier or a custom command) ─
# Auto-use .project/loop/notify.sh when present and nothing else is configured, so
# escalations reach your phone without extra wiring (see docs/REMOTE.md).
if [ -z "${SHIPYARD_NOTIFY_CMD:-}" ] && [ -x "$LOOP_DIR/notify.sh" ]; then
    SHIPYARD_NOTIFY_CMD="$LOOP_DIR/notify.sh"
fi
shipyard_notify() {
    local msg; msg="$(printf '%s' "$1" | shipyard_redact)"
    echo "🔔 $msg"
    [ -n "${SHIPYARD_NOTIFY_CMD:-}" ] && "${SHIPYARD_NOTIFY_CMD}" "$msg" 2>/dev/null || true
}
log() { echo "── $*"; }

# ── state.json helpers (best-effort, atomic) ─────────────────────────────────
# All state mutations are serialized with flock (_with_lock, from claude-invoke.sh)
# so concurrent process_issue workers (SHIPYARD_PARALLELISM>1) can't lose updates.
# NB: the *_unlocked bodies must never call another locked helper — nesting the
# same lock file would self-deadlock flock. Each locked helper is self-contained.
_state_set() { _with_lock "${STATE}.lock" _state_set_unlocked "$1"; }
_state_set_unlocked() {   # _state_set_unlocked <jq-expression>
    local tmp="$STATE.tmp.$$"
    jq "$1" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
set_current_issue() { _state_set ".loop.current_issue=${1:-null} | .loop.status=\"running\""; }
bump_attempt() { _with_lock "${STATE}.lock" _bump_attempt_unlocked "$1"; }  # echoes new count
_bump_attempt_unlocked() {
    local n="$1" cur tmp="$STATE.tmp.$$"
    cur="$(jq -r ".loop.attempts[\"$n\"] // 0" "$STATE")"
    cur=$((cur + 1))
    jq ".loop.attempts[\"$n\"]=$cur" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
    echo "$cur"
}
# Record a structured blocker (issue + kind + human-readable cause + the exact
# command the human should run). Uses --arg so reason/remediation can contain any
# characters. Keeps escalated_issues (numbers) for backward-compat.
_record_blocker() { _with_lock "${STATE}.lock" _record_blocker_unlocked "$@"; }
_record_blocker_unlocked() {  # _record_blocker <issue> <kind> <reason> <remediation>
    local n="$1" kind="$2" reason="$3" rem="$4" tmp="$STATE.tmp.$$"
    jq --argjson n "$n" --arg k "$kind" --arg r "$reason" --arg m "$rem" \
       '.loop.escalated_issues += [$n] | .loop.status="blocked"
        | .loop.blockers = ((.loop.blockers // []) + [{issue:$n,kind:$k,reason:$r,remediation:$m}])' \
       "$STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$STATE" || rm -f "$tmp"
}

# Map an error blob to (reason, remediation). This is what turns an opaque
# "blocked" into "here is the exact command YOU need to run". Fields are joined
# with a unit-separator (0x1f) so neither can be split accidentally.
classify_blocker() {  # classify_blocker <text>  → "reason<US>remediation"
    local t="$1" reason rem
    if grep -qiE 'required scopes|missing.*scope|read:project|project.*scope|gh auth refresh' <<<"$t"; then
        reason="le jeton GitHub n'a pas le scope requis (ex. Projects v2)"
        rem="gh auth refresh -s project -s read:project"
    elif grep -qiE 'protected branch|branch protection|required status check|not allowed to push|GH006' <<<"$t"; then
        reason="une règle de protection de branche bloque le push/merge sur $SHIPYARD_BASE"
        rem="ajuste la protection de la branche $SHIPYARD_BASE (Settings → Branches) puis remets le label $SHIPYARD_TODO_LABEL"
    elif grep -qiE 'HTTP 40[13]|forbidden|not authorized|must have admin|permission|insufficient' <<<"$t"; then
        reason="permissions GitHub insuffisantes (droits repo / environnement)"
        rem="vérifie tes droits sur le repo, puis: gh auth status  (et gh auth refresh si besoin)"
    elif grep -qiE 'secret|credential|unauthorized|HTTP 401|token .* (not set|invalid)|env(ironment)? var' <<<"$t"; then
        reason="un secret / identifiant est manquant ou invalide"
        rem="ajoute le secret manquant (ex. gh secret set <NOM>) puis remets le label $SHIPYARD_TODO_LABEL"
    else
        reason="blocage non catégorisé (voir logs de la boucle)"
        rem="inspecte la PR/issue et les logs, corrige, puis remets le label $SHIPYARD_TODO_LABEL"
    fi
    printf '%s\x1f%s' "$reason" "$rem"
}

# Unified escalation: label → blocked, record the structured blocker, COMMENT on
# the issue with the exact remediation command, and notify. One place, so every
# dead-end tells the human precisely what to do.
escalate() {  # escalate <issue> <kind> <reason> <remediation> [from-label]
    local n="$1" kind="$2" reason="$3" rem="$4" from="${5:-$SHIPYARD_WIP_LABEL}"
    reason="$(printf '%s' "$reason" | shipyard_redact)"
    rem="$(printf '%s' "$rem" | shipyard_redact)"
    set_status "$n" "$from" "$SHIPYARD_BLOCKED_LABEL"
    _record_blocker "$n" "$kind" "$reason" "$rem"
    local body
    body="$(printf '🚧 **Besoin humain — la boucle est en pause sur cette issue**\n\n- **Type** : %s\n- **Cause** : %s\n- **Action à lancer par toi** :\n\n```bash\n%s\n```\n\nQuand c'\''est réglé, remets le label `%s` sur cette issue pour relancer la boucle.' \
        "$kind" "$reason" "$rem" "$SHIPYARD_TODO_LABEL")"
    gh issue comment "$n" --body "$body" >/dev/null 2>&1 || true
    [ -n "${RUN_LEDGER:-}" ] && printf 'escalated\t%s\t%s\t%s\n' "$n" "$kind" "$reason" >>"$RUN_LEDGER" 2>/dev/null || true
    shipyard_notify "🚧 Issue #$n bloquée ($kind) — à lancer: $rem"
}

# ── Label / board helpers ────────────────────────────────────────────────────
set_status() {  # set_status <issue> <remove-label> <add-label>
    local n="$1" rm="$2" add="$3"
    gh issue edit "$n" --remove-label "$rm" --add-label "$add" >/dev/null 2>&1 || \
        gh issue edit "$n" --add-label "$add" >/dev/null 2>&1 || true
}

next_todo_issue() {  # echoes the next issue number, or empty
    gh issue list --state open --label "$SHIPYARD_TODO_LABEL" \
        --json number --jq 'sort_by(.number) | .[0].number // empty' 2>/dev/null
}

loop_is_paused() {
    jq -e '.loop.status == "paused"' "$STATE" >/dev/null 2>&1
}

# Stable stack knowledge, injected into every agent prompt so the model doesn't
# rediscover the toolchain each fresh session. Reads .stack_profile from state.json;
# emits nothing when absent (backward-compatible with minimal state files).
stack_context() {
    [ -f "$STATE" ] || return 0
    jq -r '
      .stack_profile // empty
      | [ "## Stack du projet (contexte stable — ne pas redécouvrir)",
          (if (.languages // []) | length > 0 then "- Langages : " + (.languages | join(", ")) else empty end),
          (if .package_manager then "- Gestionnaire de paquets : " + .package_manager else empty end),
          ((.commands // {}) | to_entries
             | map(select(.value != null and .value != ""))
             | map("- commande `" + .key + "` : `" + .value + "`") | .[]),
          (if .notes then "- Notes : " + .notes else empty end)
        ]
      | map(select(. != null)) | join("\n")
    ' "$STATE" 2>/dev/null
}

# ── Build a prompt file from a template + runtime context ────────────────────
render_prompt() {  # render_prompt <template> <context-file> → path to a temp prompt
    local tpl="$1" ctx="$2" out sc
    out="$(mktemp)"
    cat "$tpl" >"$out"
    sc="$(stack_context)"
    if [ -n "$sc" ]; then
        printf '\n\n---\n%s\n' "$sc" >>"$out"
    fi
    printf '\n\n---\n# Contexte de la tâche\n\n' >>"$out"
    cat "$ctx" >>"$out"
    echo "$out"
}

# Hard gate on CI. Returns 0 only when every check has completed and passed.
# Crucially, it WAITS for checks to register on a brand-new PR (they don't appear
# instantly) instead of treating "no checks reported yet" as a failure — that race
# otherwise burns a wasted review/fix round. Times out to "not green" after ~5 min.
: "${SHIPYARD_CI_TIMEOUT:=300}"   # seconds
ci_is_green() {
    local pr="$1" waited=0 out rc
    while [ "$waited" -lt "$SHIPYARD_CI_TIMEOUT" ]; do
        out="$(gh pr checks "$pr" 2>&1)"; rc=$?
        if grep -qiE 'no checks reported|no checks found' <<<"$out"; then
            sleep 8; waited=$((waited + 8)); continue      # not registered yet → wait
        fi
        case "$rc" in
            0) return 0 ;;                                  # all checks passed
            8) sleep 8; waited=$((waited + 8)); continue ;; # pending → wait
            *) return 1 ;;                                  # a check failed
        esac
    done
    log "PR #$pr — CI gate timed out after ${SHIPYARD_CI_TIMEOUT}s"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Process a single issue end to end. Returns 0 on merge, 1 on escalation/failure.
# ─────────────────────────────────────────────────────────────────────────────
process_issue() {
    local n="$1"
    local branch="feat/${n}"
    local wt="$REPO_ROOT/.worktrees/issue-${n}"

    set_current_issue "$n"
    local attempt; attempt="$(bump_attempt "$n")"
    if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
        log "issue #$n exceeded max attempts ($MAX_ATTEMPTS) → escalate"
        escalate "$n" "max-attempts" \
            "l'issue a été retentée $MAX_ATTEMPTS fois sans aboutir" \
            "inspecte l'issue et la dernière PR ; précise ou scinde la spec, puis remets le label $SHIPYARD_TODO_LABEL"
        return 1
    fi

    log "issue #$n — attempt $attempt/$MAX_ATTEMPTS"
    set_status "$n" "$SHIPYARD_TODO_LABEL" "$SHIPYARD_WIP_LABEL"

    # Fresh worktree off the latest base branch. Serialized: concurrent workers
    # touching the shared .git (worktree registry + ref creation) can race.
    _setup_worktree() {
        git fetch --quiet origin "$SHIPYARD_BASE" || true
        rm -rf "$wt"
        git worktree remove --force "$wt" 2>/dev/null || true
        git worktree add -B "$branch" "$wt" "origin/$SHIPYARD_BASE" >/dev/null 2>&1 \
            || git worktree add -B "$branch" "$wt" >/dev/null
    }
    _with_lock "$REPO_ROOT/.project/.git.lock" _setup_worktree

    # Issue context (goal + acceptance criteria live in the issue body).
    local ctx; ctx="$(mktemp)"
    gh issue view "$n" --json number,title,body,labels \
        --template '## Issue #{{.number}} — {{.title}}

{{.body}}

Labels: {{range .labels}}{{.name}} {{end}}' >"$ctx" 2>/dev/null || echo "Issue #$n" >"$ctx"

    # ── DEV step (Sonnet, fresh context) ─────────────────────────────────────
    local dev_prompt dev_out commit_msg
    dev_prompt="$(render_prompt "$LOOP_DIR/prompt-dev.md" "$ctx")"
    if ! (
        cd "$wt"
        claude_invoke sonnet "$dev_prompt" >"$wt/.shipyard-dev.out"
    ); then
        log "dev session failed for #$n"
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "max-attempts" \
                "la session de développement a échoué $attempt fois" \
                "inspecte les logs et l'issue, corrige la cause, puis remets le label $SHIPYARD_TODO_LABEL"
        fi
        return 1
    fi
    dev_out="$(shipyard_redact <"$wt/.shipyard-dev.out")"
    printf '%s\n' "$dev_out" >"$wt/.shipyard-dev.out"

    # The agent can raise a non-code blocker it cannot resolve itself (a missing
    # secret/token, a permission, an external service): it emits NEEDS-HUMAN: … .
    # We escalate with that message instead of committing empty work.
    if grep -q '^NEEDS-HUMAN:' <<<"$dev_out"; then
        local need; need="$(grep -m1 '^NEEDS-HUMAN:' <<<"$dev_out" | sed 's/^NEEDS-HUMAN:[[:space:]]*//')"
        log "issue #$n — dev signaled a human-blocking dependency"
        git worktree remove --force "$wt" 2>/dev/null || true
        escalate "$n" "needs-human" "$need" \
            "règle le point ci-dessus (voir le commentaire), puis remets le label $SHIPYARD_TODO_LABEL"
        return 1
    fi

    commit_msg="$(grep -m1 '^COMMIT:' <<<"$dev_out" | sed 's/^COMMIT:[[:space:]]*//')"
    [ -z "$commit_msg" ] && commit_msg="feat: address issue #$n"
    commit_msg="$(printf '%s' "$commit_msg" | shipyard_redact)"

    # Orchestrator owns git (deterministic). Capture output so a push/auth failure
    # is classified into an actionable blocker, distinct from "nothing produced".
    local gitout
    gitout="$( cd "$wt" && {
        git add -A
        if git diff --cached --quiet; then echo '__NOCHANGES__'; exit 42; fi
        git commit -q -m "$commit_msg" -m "Closes #$n"
        git push -q -u origin "$branch" --force-with-lease
      } 2>&1 )" || {
        if grep -q '__NOCHANGES__' <<<"$gitout"; then
            log "no changes produced for #$n → escalate"
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "no-output" \
                "l'agent n'a produit aucun changement de fichier" \
                "inspecte l'issue (spec trop vague ?) puis remets le label $SHIPYARD_TODO_LABEL"
        else
            log "commit/push failed for #$n → escalate"
            local cb reason rem; cb="$(classify_blocker "$gitout")"
            reason="${cb%%$'\x1f'*}"; rem="${cb#*$'\x1f'}"
            escalate "$n" "push-failed" "$reason" "$rem"
        fi
        return 1; }

    # ── Open (or reuse) the PR against the integration branch ────────────────
    local pr
    pr="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)"
    local prout=""
    if [ -z "$pr" ]; then
        prout="$(gh pr create --base "$SHIPYARD_BASE" --head "$branch" \
            --title "$commit_msg" --body "Automated by shipyard loop. Closes #$n." 2>&1)" || true
        pr="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)"
    fi
    if [ -z "$pr" ]; then
        log "could not open PR for #$n → escalate"
        local cb reason rem; cb="$(classify_blocker "$prout")"
        reason="${cb%%$'\x1f'*}"; rem="${cb#*$'\x1f'}"
        escalate "$n" "pr-failed" "$reason" "$rem"
        return 1
    fi
    set_status "$n" "$SHIPYARD_WIP_LABEL" "$SHIPYARD_REVIEW_LABEL"
    shipyard_notify "📤 PR #$pr ouverte pour l'issue #$n"

    # ── REVIEW loop: HARD gate (CI) first, agent judgement second ────────────
    local round=0 verdict review_out review_ctx review_prompt
    while [ "$round" -lt "$MAX_REVIEW" ]; do
        round=$((round + 1))

        # Hard gate: objective signals. Waits for checks to register + complete.
        if ! ci_is_green "$pr"; then
            log "PR #$pr — CI not green (round $round)"
            verdict="request-changes"
            review_out="La CI n'est pas verte. Corrige les échecs (tests, lint, Trivy)."
        else
            # Fresh reviewer session (Opus) — judges acceptance criteria only.
            review_ctx="$(mktemp)"
            { cat "$ctx"
              echo; echo "## Diff de la PR #$pr"; echo
              gh pr diff "$pr" 2>/dev/null | head -c 60000
            } >"$review_ctx"
            review_prompt="$(render_prompt "$LOOP_DIR/prompt-review.md" "$review_ctx")"
            review_out="$(claude_invoke opus "$review_prompt")" || { log "review failed #$pr"; break; }
            verdict="$(grep -m1 '^VERDICT:' <<<"$review_out" | sed 's/^VERDICT:[[:space:]]*//' | tr 'A-Z' 'a-z')"
        fi

        if [ "$verdict" = "approve" ]; then
            # Serialize merges: two PRs merging into the same base at once can trip
            # "base out of date" / branch-protection races. One at a time is safe.
            _do_merge() { gh pr merge "$pr" --squash --delete-branch >/dev/null 2>&1 \
                            || gh pr merge "$pr" --squash >/dev/null 2>&1; }
            _with_lock "$REPO_ROOT/.project/.merge.lock" _do_merge \
                || { log "merge failed for PR #$pr"; break; }
            git worktree remove --force "$wt" 2>/dev/null || true
            log "issue #$n merged via PR #$pr ✅"
            [ -n "${RUN_LEDGER:-}" ] && printf 'merged\t%s\t%s\t%s\n' "$n" "$pr" "$round" >>"$RUN_LEDGER" 2>/dev/null || true
            shipyard_notify "✅ Issue #$n mergée (PR #$pr)"
            return 0
        fi

        # request-changes → re-inject failures as context and fix (pressure cooker)
        log "PR #$pr — request-changes (round $round/$MAX_REVIEW), fixing"
        local fix_ctx fix_prompt fix_out
        fix_ctx="$(mktemp)"
        { cat "$ctx"; echo; echo "## Retour de review à corriger"; echo; echo "$review_out"; } >"$fix_ctx"
        fix_prompt="$(render_prompt "$LOOP_DIR/prompt-dev.md" "$fix_ctx")"
        ( cd "$wt"; claude_invoke sonnet "$fix_prompt" >"$wt/.shipyard-fix.out" ) \
            || { log "fix session failed #$n"; break; }
        fix_out="$(shipyard_redact <"$wt/.shipyard-fix.out" 2>/dev/null)"
        printf '%s\n' "$fix_out" >"$wt/.shipyard-fix.out"
        # A human-blocking dependency can surface during a fix round too.
        if grep -q '^NEEDS-HUMAN:' <<<"$fix_out"; then
            local need2; need2="$(grep -m1 '^NEEDS-HUMAN:' <<<"$fix_out" | sed 's/^NEEDS-HUMAN:[[:space:]]*//')"
            log "issue #$n — fix step signaled a human-blocking dependency"
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "needs-human" "$need2" \
                "règle le point ci-dessus puis remets le label $SHIPYARD_TODO_LABEL" "$SHIPYARD_REVIEW_LABEL"
            return 1
        fi
        ( cd "$wt"
          fixmsg="$(grep -m1 '^COMMIT:' "$wt/.shipyard-fix.out" 2>/dev/null | sed 's/^COMMIT:[[:space:]]*//')"
          git add -A
          git diff --cached --quiet || git commit -q -m "${fixmsg:-fix: address review on #$n}"
          git push -q origin "$branch" --force-with-lease
        ) || { log "fix push failed #$n"; break; }
    done

    # Review budget exhausted → escalate (actionable).
    escalate "$n" "review-exhausted" \
        "la PR #$pr n'a pas été validée après $MAX_REVIEW tours de review" \
        "relis la PR #$pr et ses commentaires, corrige à la main si besoin, puis remets le label $SHIPYARD_TODO_LABEL" \
        "$SHIPYARD_REVIEW_LABEL"
    return 1
}

# ── Sprint retrospective (auto, end of a drained sprint) ─────────────────────
# Where the retro file lives: the vault's sprints dir in vault mode, else the
# repo's .project/sprints. Mirrors render-templates.sh path resolution.
retro_dir() {
    local vp; vp="$(jq -r '.vault_project_path // ""' "$STATE" 2>/dev/null || true)"
    if [ -n "$vp" ] && [ "$vp" != "null" ]; then echo "$vp/sprints"; else echo "$REPO_ROOT/.project/sprints"; fi
}

# Generate a retrospective from the run LEDGER. Facts are computed here
# (deterministic, authoritative); the qualitative analysis is a fresh, cheap
# agent session grounded strictly in those facts. Writes a markdown file and —
# for async phone review — opens a GitHub issue (idempotent per sprint). Fully
# best-effort: never fails the loop. Disable with SHIPYARD_RETRO=0; file-only
# with SHIPYARD_RETRO_ISSUE=0; model via SHIPYARD_RETRO_MODEL (default haiku).
sprint_retrospective() {
    [ -f "${RUN_LEDGER:-}" ] || return 0
    local merged_ct esc_ct sprint_no today dir file facts prompt prose pend
    merged_ct="$(grep -c '^merged' "$RUN_LEDGER" || true)";       merged_ct="${merged_ct:-0}"
    esc_ct="$(grep -c '^escalated' "$RUN_LEDGER" || true)";       esc_ct="${esc_ct:-0}"
    [ "$merged_ct" -eq 0 ] && [ "$esc_ct" -eq 0 ] && return 0     # nothing worth a retro

    sprint_no="$(jq -r '.current_sprint // 1' "$STATE" 2>/dev/null || echo 1)"
    today="$(date +%F 2>/dev/null || echo '')"
    dir="$(retro_dir)"; mkdir -p "$dir" 2>/dev/null || true
    file="$dir/retro-sprint-$(printf '%03d' "$sprint_no" 2>/dev/null || echo "$sprint_no").md"
    pend="$(jq -r '(.loop.blockers // []) | length' "$STATE" 2>/dev/null || echo 0)"

    # 1) Deterministic facts block.
    facts="$(mktemp)"
    {
        echo "### Résultats (faits)"
        echo "- Issues livrées (mergées) : $merged_ct"
        grep '^merged' "$RUN_LEDGER" 2>/dev/null | while IFS=$'\t' read -r _ n pr rounds; do
            echo "  - #$n (PR #$pr, ${rounds:-?} tour(s) de review)"
        done
        echo "- Issues escaladées (bloquées) : $esc_ct"
        grep '^escalated' "$RUN_LEDGER" 2>/dev/null | while IFS=$'\t' read -r _ n kind reason; do
            echo "  - #$n — $kind : $reason"
        done
        echo "- Blocages en attente d'action humaine : $pend"
    } >"$facts"

    # 2) Qualitative analysis — fresh, cheap agent, grounded in the facts.
    prose=""
    if [ "${SHIPYARD_RETRO_ANALYSIS:-1}" != 0 ]; then
        prompt="$(mktemp)"
        cat "$LOOP_DIR/prompt-retro.md" >"$prompt"
        { printf '\n\n---\n# Faits du sprint %s\n\n' "$sprint_no"; cat "$facts"; } >>"$prompt"
        prose="$(claude_invoke "${SHIPYARD_RETRO_MODEL:-haiku}" "$prompt" 2>/dev/null || true)"
        rm -f "$prompt"
    fi

    # 3) Assemble the file (facts authoritative; prose is the qualitative layer).
    {
        echo "# Rétrospective — Sprint $sprint_no"
        [ -n "$today" ] && echo "> Généré automatiquement par la boucle shipyard le $today"
        echo
        cat "$facts"
        if [ -n "$prose" ]; then echo; echo "### Analyse"; echo; printf '%s\n' "$prose"; fi
    } >"$file"
    rm -f "$facts"
    log "retrospective written: $file"

    # 4) Async surface: one GitHub issue per sprint (idempotent), so you review it
    #    from your phone. Labelled 'retro' only — never status:todo, so the loop
    #    won't pick it up as work.
    if [ "${SHIPYARD_RETRO_ISSUE:-1}" != 0 ]; then
        local title existing
        title="chore(retro): sprint $sprint_no — $merged_ct livrée(s), $esc_ct bloquée(s)"
        existing="$(gh issue list --state open --search "chore(retro): sprint $sprint_no in:title" \
                      --json number --jq '.[0].number // empty' 2>/dev/null || true)"
        if [ -z "$existing" ]; then
            gh label create retro --color 5319e7 --description "Sprint retrospective" >/dev/null 2>&1 || true
            if gh issue create --title "$title" --label retro --body-file "$file" >/dev/null 2>&1; then
                log "retrospective issue opened"
            else
                log "could not open retro issue (non-fatal — file is on disk)"
            fi
        else
            log "retro issue already open (#$existing) — updated the file only"
        fi
    fi

    shipyard_notify "📊 Rétro sprint $sprint_no prête — $merged_ct livrée(s), $esc_ct bloquée(s)"
    return 0
}

# On (re)start, resume any issue a previous run left mid-flight (killed, rebooted, or
# picked up after a long back-off). status:blocked issues are left alone — they wait for
# a human. process_issue is idempotent (reuses the existing branch/PR), so this is safe.
recover_in_flight() {
    local n lbl handled=0
    for lbl in "$SHIPYARD_WIP_LABEL" "$SHIPYARD_REVIEW_LABEL"; do
        for n in $(gh issue list --state open --label "$lbl" \
                     --json number --jq 'sort_by(.number) | .[].number' 2>/dev/null); do
            log "resume: recovering in-flight issue #$n (was '$lbl')"
            process_issue "$n" || log "issue #$n did not complete on recovery"
            handled=1
        done
    done
    [ "$handled" = 1 ] && log "resume: in-flight recovery done"
    return 0
}

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
    command -v gh   >/dev/null || { echo "gh not found" >&2; exit 1; }
    command -v jq   >/dev/null || { echo "jq not found" >&2; exit 1; }
    command -v claude >/dev/null || { echo "claude (Claude Code) not found" >&2; exit 1; }

    log "shipyard loop: base=$SHIPYARD_BASE max_iters=$MAX_ITERS parallelism=$SHIPYARD_PARALLELISM"
    [ -n "${SHIPYARD_FALLBACK_API_KEY:-}" ] && log "API-key fallback: armed (used only if Max is rate-limited)"
    if [ "$SHIPYARD_PARALLELISM" -gt 1 ] && ! command -v flock >/dev/null 2>&1; then
        log "WARN: SHIPYARD_PARALLELISM>1 but flock is missing — falling back to sequential (unsafe otherwise)"
        SHIPYARD_PARALLELISM=1
    fi
    # Per-run ledger: process_issue/escalate append merged/escalated rows here; the
    # end-of-run retrospective reads it. Kept for the whole run (recovery included).
    RUN_LEDGER="$(mktemp)"; trap 'rm -f "$RUN_LEDGER"' EXIT
    _state_set '.loop.status="running" | .loop.paused_reason=null | .loop.resume_after=null'
    recover_in_flight
    local iter=0 issue
    while [ "$iter" -lt "$MAX_ITERS" ]; do
        # /deliver pause writes this status asynchronously. Honour it only at
        # iteration boundaries so an in-flight issue reaches a consistent state.
        if loop_is_paused; then
            log "manual pause observed between iterations"
            break
        fi
        # Throttle: with parallelism, wait for a free worker slot before pulling more.
        if [ "$SHIPYARD_PARALLELISM" -gt 1 ]; then
            while [ "$(jobs -rp | wc -l)" -ge "$SHIPYARD_PARALLELISM" ]; do
                wait -n 2>/dev/null || sleep 1
            done
        fi
        issue="$(next_todo_issue)"
        if [ -z "$issue" ]; then
            log "queue empty — nothing left in $SHIPYARD_TODO_LABEL"
            break
        fi
        iter=$((iter + 1))
        if [ "$SHIPYARD_PARALLELISM" -gt 1 ]; then
            # Claim the issue synchronously (todo→wip) BEFORE backgrounding so the next
            # next_todo_issue can't hand the same issue to a second worker.
            set_status "$issue" "$SHIPYARD_TODO_LABEL" "$SHIPYARD_WIP_LABEL"
            ( process_issue "$issue" || log "issue #$issue did not merge (see above)" ) &
        else
            process_issue "$issue" || log "issue #$issue did not merge (see above)"
        fi
    done
    [ "$SHIPYARD_PARALLELISM" -gt 1 ] && wait   # drain in-flight workers
    [ "$iter" -ge "$MAX_ITERS" ] && log "iteration cap reached ($MAX_ITERS)"
    log "loop finished after $iter iteration(s)"
    # A manual pause is durable: leave the loop paused so /deliver status reports
    # the truth. /deliver resume starts a new run, which clears the pause metadata.
    if loop_is_paused; then
        _state_set '.loop.current_issue=null'
        shipyard_notify "⏸️ Boucle en pause manuelle après $iter itération(s)"
        return 0
    fi
    # Sprint drained (or cap hit) with real work done → auto retrospective. This
    # runs BEFORE the final idle checkpoint on purpose: sprint_retrospective calls
    # claude_invoke, whose success checkpoint flips status back to "running", so
    # idle must be the last write to leave a correct terminal state.
    if [ "$iter" -gt 0 ] && [ "${SHIPYARD_RETRO:-1}" != 0 ]; then
        sprint_retrospective || log "retrospective step failed (non-fatal)"
    fi
    # Preserve a terminal blocker instead of masking it as idle. A later run will
    # set running again after the human has returned the issue to status:todo.
    if jq -e '.loop.status == "blocked"' "$STATE" >/dev/null 2>&1; then
        _state_set '.loop.current_issue=null'
    else
        _state_set '.loop.status="idle" | .loop.current_issue=null'
    fi
    shipyard_notify "🏁 Boucle terminée — $iter itération(s)"
}

if [ "${SHIPYARD_SOURCE_ONLY:-0}" != 1 ]; then
    main "$@"
fi
