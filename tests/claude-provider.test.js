import test from 'node:test';
import assert from 'node:assert/strict';

import { ClaudeProvider } from '../server/providers/claude-provider.js';

test('claude provider surfaces sdk result-string errors instead of Unknown error', () => {
  const provider = new ClaudeProvider();
  const events = [];
  const conn = { listeners: new Set([(event) => events.push(event)]) };

  provider._handleEvent(conn, {
    type: 'result',
    subtype: 'success',
    is_error: true,
    result: 'Your organization does not have access to Claude.',
    usage: {
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
    },
  });

  assert.deepEqual(events.at(-1), {
    type: 'turn_error',
    message: 'Your organization does not have access to Claude.',
  });
});
