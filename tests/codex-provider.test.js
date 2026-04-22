import test from 'node:test';
import assert from 'node:assert/strict';

import { CodexProvider } from '../server/providers/codex-provider.js';

test('codex thread launch params force never-approve full access', () => {
  const provider = new CodexProvider();
  const conn = { cwd: '/tmp/clawmux-codex-test' };

  assert.deepEqual(provider._threadStartParams(conn), {
    cwd: '/tmp/clawmux-codex-test',
    approvalPolicy: 'never',
    sandbox: 'danger-full-access',
  });

  assert.deepEqual(provider._threadResumeParams(conn, 'thr_123'), {
    threadId: 'thr_123',
    cwd: '/tmp/clawmux-codex-test',
    approvalPolicy: 'never',
    sandbox: 'danger-full-access',
    persistExtendedHistory: false,
  });
});

test('codex turn params keep never-approve full access on resumed threads', () => {
  const provider = new CodexProvider();
  const conn = {
    threadId: 'thr_123',
    effortLevel: 'high',
  };

  assert.deepEqual(provider._turnStartParams(conn, 'hello'), {
    threadId: 'thr_123',
    input: [{ type: 'text', text: 'hello' }],
    effort: 'high',
    approvalPolicy: 'never',
    sandboxPolicy: { type: 'dangerFullAccess' },
  });
});

test('codex treats request id 0 as a valid approval callback', () => {
  const provider = new CodexProvider();
  let approval = null;
  provider.respondPermission = (_conn, requestId, allowed) => {
    approval = { requestId, allowed };
  };

  provider._handleNotification(
    { alive: true },
    'item/commandExecution/requestApproval',
    { threadId: 'thr_123', turnId: 'turn_123', itemId: 'item_123' },
    0,
  );

  assert.deepEqual(approval, { requestId: 0, allowed: true });
});
