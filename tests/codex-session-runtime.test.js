import test from 'node:test';
import assert from 'node:assert/strict';

import { CodexProvider } from '../server/providers/codex-provider.js';
import { CodexSessionRuntime, isRecoverableThreadResumeError } from '../server/providers/codex-session-runtime.js';

class FakeCodexClient {
  constructor() {
    this.requests = [];
    this.notifications = [];
    this.closed = false;
  }

  start() {
    this.started = true;
  }

  async request(method, params) {
    this.requests.push({ method, params });
    if (method === 'initialize') return { userAgent: 'fake-codex' };
    if (method === 'thread/resume') throw new Error('thread/resume failed: not found');
    if (method === 'thread/start') return { thread: { id: 'thr_new' } };
    return {};
  }

  notify(method, params) {
    this.notifications.push({ method, params });
  }

  close() {
    this.closed = true;
  }
}

test('codex session runtime initializes, notifies initialized, and falls back from stale resume', async () => {
  const provider = new CodexProvider();
  const events = [];
  const clients = [];
  provider._writeSessionFile = () => {};
  provider._emit = (_conn, event) => events.push(event);

  const runtime = new CodexSessionRuntime(
    provider,
    { cwd: '/tmp/clawmux-codex-test', resume: 'thr_missing' },
    {
      clientFactory: () => {
        const client = new FakeCodexClient();
        clients.push(client);
        return client;
      },
    },
  );

  const conn = await runtime.start();
  const client = clients[0];

  assert.equal(conn.threadId, 'thr_new');
  assert.deepEqual(
    client.requests.map((request) => request.method),
    ['initialize', 'thread/resume', 'thread/start'],
  );
  assert.deepEqual(client.notifications, [{ method: 'initialized', params: undefined }]);
  assert.deepEqual(events, [{ type: 'session_ready', sessionId: 'thr_new' }]);
});

test('codex resume fallback only treats thread/resume missing-thread errors as recoverable', () => {
  assert.equal(isRecoverableThreadResumeError(new Error('thread/resume failed: not found')), true);
  assert.equal(isRecoverableThreadResumeError(new Error('thread/resume failed: no rollout found for thread id')), true);
  assert.equal(isRecoverableThreadResumeError(new Error('model/list failed: not found')), false);
  assert.equal(isRecoverableThreadResumeError(new Error('thread/resume failed: permission denied')), false);
});
