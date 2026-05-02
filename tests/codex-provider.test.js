import test from 'node:test';
import assert from 'node:assert/strict';

import { CodexProvider } from '../server/providers/codex-provider.js';

test('codex app-server args use supported config overrides', () => {
  const provider = new CodexProvider();
  const args = provider._serverArgs();

  assert.deepEqual(args, ['app-server', '-c', 'approval_policy="never"', '-c', 'sandbox_mode="danger-full-access"']);
  assert.equal(args.includes('--listen'), false);
  assert.equal(args.includes('--dangerously-bypass-approvals-and-sandbox'), false);
});

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
    excludeTurns: true,
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

test('codex answers user-input requests so app-server cannot wedge waiting for hidden input', () => {
  const provider = new CodexProvider();
  const sent = [];
  const conn = {
    alive: true,
    ws: { send: (payload) => sent.push(JSON.parse(payload)) },
    listeners: new Set(),
  };

  provider._handleNotification(
    conn,
    'item/tool/requestUserInput',
    {
      questions: [
        {
          id: 'trust',
          header: 'Trust',
          question: 'Trust this workspace?',
          options: [{ label: 'Yes', description: 'Trust this workspace' }],
        },
        {
          id: 'fallback',
          header: 'Continue',
          question: 'Continue?',
        },
      ],
    },
    0,
  );

  assert.deepEqual(sent, [
    {
      id: 0,
      result: {
        answers: {
          trust: { answers: ['Yes'] },
          fallback: { answers: ['ok'] },
        },
      },
    },
  ]);
});

test('codex cancels unsupported MCP elicitations instead of leaving app-server waiting', () => {
  const provider = new CodexProvider();
  const sent = [];
  const conn = {
    alive: true,
    ws: { send: (payload) => sent.push(JSON.parse(payload)) },
    listeners: new Set(),
  };

  provider._handleNotification(conn, 'mcpServer/elicitation/request', { message: 'Need input' }, 0);

  assert.deepEqual(sent, [{ id: 0, result: { action: 'cancel' } }]);
});

test('codex ignores thread-bound notifications for a different thread', () => {
  const provider = new CodexProvider();
  const events = [];
  const conn = {
    alive: true,
    threadId: 'thr_alice',
    listeners: new Set([(event) => events.push(event)]),
  };

  provider._handleNotification(conn, 'turn/started', {
    threadId: 'thr_bob',
    turn: { id: 'turn_bob', status: 'inProgress' },
  });
  provider._handleNotification(conn, 'item/agentMessage/delta', {
    threadId: 'thr_bob',
    turnId: 'turn_bob',
    delta: 'wrong thread',
  });
  provider._handleNotification(conn, 'turn/completed', {
    threadId: 'thr_bob',
    turn: { id: 'turn_bob', status: 'completed' },
  });

  assert.equal(conn.threadId, 'thr_alice');
  assert.equal(conn.turnId, undefined);
  assert.deepEqual(events, []);
});

test('codex does not let foreign thread/started overwrite the active thread', () => {
  const provider = new CodexProvider();
  const conn = {
    alive: true,
    threadId: 'thr_alice',
    listeners: new Set(),
  };

  provider._handleNotification(conn, 'thread/started', {
    thread: { id: 'thr_bob' },
  });

  assert.equal(conn.threadId, 'thr_alice');
});

test('codex adopts thread id from thread/started only before a thread is known', () => {
  const provider = new CodexProvider();
  const conn = {
    alive: true,
    threadId: null,
    listeners: new Set(),
  };

  provider._handleNotification(conn, 'thread/started', {
    thread: { id: 'thr_new' },
  });

  assert.equal(conn.threadId, 'thr_new');
});
