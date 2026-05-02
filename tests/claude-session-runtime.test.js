import test from 'node:test';
import assert from 'node:assert/strict';

import { ClaudeProvider } from '../server/providers/claude-provider.js';
import { ClaudeSessionRuntime, isRecoverableClaudeResumeError } from '../server/providers/claude-session-runtime.js';

function waitForMicrotasks() {
  return new Promise((resolve) => setImmediate(resolve));
}

class FakeClaudeQuery {
  constructor(messages = []) {
    this.messages = [...messages];
    this.closed = false;
    this.interrupted = false;
    this.permissionModes = [];
    this.appliedSettings = [];
    this._closePromise = new Promise((resolve) => {
      this._closeResolve = resolve;
    });
  }

  async *[Symbol.asyncIterator]() {
    for (const message of this.messages) yield message;
    await this._closePromise;
  }

  async interrupt() {
    this.interrupted = true;
  }

  async setPermissionMode(mode) {
    this.permissionModes.push(mode);
  }

  async applyFlagSettings(settings) {
    this.appliedSettings.push(settings);
  }

  close() {
    this.closed = true;
    this._closeResolve();
  }
}

test('claude session runtime starts sdk query with expected options and queues user prompts', async () => {
  const provider = new ClaudeProvider();
  const events = [];
  const rawEvents = [];
  const captured = {};
  const fakeQuery = new FakeClaudeQuery([{ type: 'system', subtype: 'init', session_id: 'sess_123' }]);

  provider._emit = (_conn, event) => events.push(event);
  provider._emitRaw = (_conn, event) => rawEvents.push(event);

  const runtime = new ClaudeSessionRuntime(
    provider,
    {
      cwd: '/tmp/clawmux-claude',
      model: 'claude-opus-4-7',
      effortLevel: 'max',
      permissionMode: 'bypassPermissions',
      agentId: 'river',
    },
    {
      queryImpl: ({ prompt, options }) => {
        captured.prompt = prompt;
        captured.options = options;
        return fakeQuery;
      },
      sessionExists: () => true,
    },
  );

  await runtime.start();
  await waitForMicrotasks();

  assert.equal(captured.options.cwd, '/tmp/clawmux-claude');
  assert.equal(captured.options.model, 'claude-opus-4-7');
  assert.equal(captured.options.effort, 'max');
  assert.equal(captured.options.permissionMode, 'bypassPermissions');
  assert.equal(captured.options.allowDangerouslySkipPermissions, true);
  assert.equal(captured.options.includePartialMessages, true);
  assert.equal(captured.options.env.CMX_AGENT, 'river');
  assert.equal(captured.options.env.CLAUDE_AGENT_SDK_CLIENT_APP, 'clawmux/1.0.0');
  assert.deepEqual(events, [{ type: 'session_ready', sessionId: 'sess_123' }]);

  const promptIter = captured.prompt[Symbol.asyncIterator]();
  runtime.send('hello');
  const prompt = await promptIter.next();

  assert.equal(prompt.value.type, 'user');
  assert.equal(prompt.value.message.role, 'user');
  assert.equal(prompt.value.message.content[0].text, 'hello');
  assert.equal(
    rawEvents.some((event) => event.direction === 'out' && event.summary === 'user'),
    true,
  );

  runtime.close();
});

test('claude session runtime bridges sdk permission prompts through respondPermission', async () => {
  const provider = new ClaudeProvider();
  const events = [];
  const captured = {};
  const fakeQuery = new FakeClaudeQuery();

  provider._emit = (_conn, event) => events.push(event);
  provider._emitRaw = () => {};

  const runtime = new ClaudeSessionRuntime(
    provider,
    { cwd: '/tmp/clawmux-claude' },
    {
      queryImpl: ({ options }) => {
        captured.options = options;
        return fakeQuery;
      },
      sessionExists: () => true,
    },
  );

  await runtime.start();

  const decision = captured.options.canUseTool('Edit', { file_path: 'notes.txt' }, { toolUseID: 'tool_1' });
  await waitForMicrotasks();

  assert.deepEqual(events, [
    { type: 'permission_request', id: 'tool_1', tool: 'Edit', input: { file_path: 'notes.txt' } },
  ]);

  runtime.respondPermission('tool_1', true);
  assert.deepEqual(await decision, { behavior: 'allow', toolUseID: 'tool_1' });

  runtime.close();
});

test('claude session runtime updates effort through applyFlagSettings', async () => {
  const provider = new ClaudeProvider();
  const fakeQuery = new FakeClaudeQuery();
  provider._emit = () => {};
  provider._emitRaw = () => {};

  const runtime = new ClaudeSessionRuntime(
    provider,
    { cwd: '/tmp/clawmux-claude' },
    {
      queryImpl: () => fakeQuery,
      sessionExists: () => true,
    },
  );

  await runtime.start();
  await runtime.setThinkingLevel('max');

  assert.deepEqual(fakeQuery.appliedSettings, [{ effortLevel: 'max' }]);

  runtime.close();
});

test('claude session runtime skips sdk startup and emits resume_failed for stale sessions', async () => {
  const provider = new ClaudeProvider();
  const events = [];
  let queryCalled = false;

  provider._emit = (_conn, event) => events.push(event);
  provider._emitRaw = () => {};

  const runtime = new ClaudeSessionRuntime(
    provider,
    { cwd: '/tmp/clawmux-claude', resume: 'sess_missing' },
    {
      queryImpl: () => {
        queryCalled = true;
        return new FakeClaudeQuery();
      },
      sessionExists: () => false,
    },
  );

  await runtime.start();
  await waitForMicrotasks();

  assert.equal(queryCalled, false);
  assert.deepEqual(events, [{ type: 'resume_failed' }]);
});

test('claude resume fallback only treats resume-specific missing-session errors as recoverable', () => {
  assert.equal(isRecoverableClaudeResumeError(new Error('resume failed: session not found')), true);
  assert.equal(isRecoverableClaudeResumeError(new Error('resume failed: no conversation found')), true);
  assert.equal(isRecoverableClaudeResumeError(new Error('model lookup failed: not found')), false);
  assert.equal(isRecoverableClaudeResumeError(new Error('permission denied')), false);
});
