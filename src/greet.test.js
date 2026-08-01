const test = require('node:test');
const assert = require('node:assert/strict');
const { greet } = require('./greet.js');

test('greet("Ada") returns "Hello, Ada!"', () => {
  assert.equal(greet('Ada'), 'Hello, Ada!');
});
