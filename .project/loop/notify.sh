#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# notify.sh — push a shipyard loop event to your phone.
#
# The loop calls this (via SHIPYARD_NOTIFY_CMD) at every meaningful moment: PR
# opened, PR merged, issue escalated (needs human), quota back-off, loop finished.
# Pluggable backends, chosen by which env vars are set. NONE set → silent no-op,
# so the loop is never blocked or slowed by notifications.
#
# Usage:  notify.sh "message"
#
# Backends, in order. Happy native is preferred (same encrypted push as the app you
# already pair to pilot the loop — no extra account or app). The others are for when
# you are NOT running under Happy. Every configured backend fires; none set → no-op.
#
#   Happy native (auto when the `happy` CLI is installed & paired on the VPS):
#       happy notify "<msg>"     — disable with SHIPYARD_NOTIFY_HAPPY=0
#   ntfy (no account — install the ntfy app, subscribe to the topic):
#       SHIPYARD_NTFY_TOPIC=<a-long-random-topic>      # acts as the secret
#       SHIPYARD_NTFY_URL=https://ntfy.sh              # optional, self-host ok
#   Telegram (create a bot via @BotFather, get your chat id):
#       SHIPYARD_TELEGRAM_TOKEN=123456:ABC...
#       SHIPYARD_TELEGRAM_CHAT=987654321
#   Generic JSON webhook (Slack/Discord/n8n/…):
#       SHIPYARD_WEBHOOK_URL=https://...
#
# Priority/tags are inferred from the leading emoji so escalations buzz louder.
# ─────────────────────────────────────────────────────────────────────────────
msg="${1:-shipyard}"
title="${SHIPYARD_NOTIFY_TITLE:-shipyard}"
: "${SHIPYARD_NOTIFY_TIMEOUT:=10}"

_with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$SHIPYARD_NOTIFY_TIMEOUT" "$@"; else "$@"; fi; }

# ── Happy native push (preferred) ────────────────────────────────────────────
# Uses the same end-to-end-encrypted channel as the Happy app you pilot from. Needs
# the `happy` CLI installed and paired on this host (`happy` run at least once).
if [ "${SHIPYARD_NOTIFY_HAPPY:-auto}" != "0" ] && command -v happy >/dev/null 2>&1; then
  _with_timeout happy notify "$msg" >/dev/null 2>&1 || true
fi

# ── HTTP backends (only if curl is available) ────────────────────────────────
command -v curl >/dev/null 2>&1 || exit 0

prio="default"; tags="robot"
case "$msg" in
  "🚧"*|"‼️"*|"❌"*) prio="high"; tags="warning" ;;
  "⏸️"*)             prio="high"; tags="hourglass_flowing_sand" ;;
  "✅"*|"🏁"*)       prio="default"; tags="white_check_mark" ;;
  "📤"*)             prio="low"; tags="outbox_tray" ;;
esac

if [ -n "${SHIPYARD_NTFY_TOPIC:-}" ]; then
  curl -fsS -m "$SHIPYARD_NOTIFY_TIMEOUT" \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
    -d "$msg" "${SHIPYARD_NTFY_URL:-https://ntfy.sh}/$SHIPYARD_NTFY_TOPIC" >/dev/null 2>&1 || true
fi

if [ -n "${SHIPYARD_TELEGRAM_TOKEN:-}" ] && [ -n "${SHIPYARD_TELEGRAM_CHAT:-}" ]; then
  curl -fsS -m "$SHIPYARD_NOTIFY_TIMEOUT" \
    "https://api.telegram.org/bot${SHIPYARD_TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${SHIPYARD_TELEGRAM_CHAT}" \
    --data-urlencode "text=${title}: ${msg}" >/dev/null 2>&1 || true
fi

if [ -n "${SHIPYARD_WEBHOOK_URL:-}" ]; then
  body="$(jq -nc --arg t "$title" --arg m "$msg" --arg p "$prio" \
      '{title:$t, message:$m, priority:$p}' 2>/dev/null \
      || printf '{"title":"%s","message":"%s"}' "$title" "$msg")"
  curl -fsS -m "$SHIPYARD_NOTIFY_TIMEOUT" -H 'Content-Type: application/json' -d "$body" "$SHIPYARD_WEBHOOK_URL" >/dev/null 2>&1 || true
fi

exit 0
