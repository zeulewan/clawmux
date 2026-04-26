import test from 'node:test';
import assert from 'node:assert/strict';

import ProviderSession, { getRawEvents, clearRawEvents } from '../server/provider-session.js';

function makeFakeProvider() {
  const calls = { connect: [], close: [] };
  const provider = {
    connect: async (config) => {
      calls.connect.push(config);
      return { alive: true, listeners: new Set() };
    },
    onEvent: (conn, callback) => {
      conn._callback = callback;
      return () => {
        conn._callback = null;
      };
    },
    close: (conn) => {
      calls.close.push(conn);
      conn.alive = false;
    },
    send: () => {},
    interrupt: () => {},
    respondPermission: () => {},
  };
  return { provider, calls };
}

function makeSession(agentId = 'puck') {
  const agentProcs = new Map();
  const session = new ProviderSession(() => {}, '/tmp/clawmux-provider-session-test', agentId, agentProcs);
  const fake = makeFakeProvider();
  session.provider = fake.provider;
  return { session, calls: fake.calls, agentProcs };
}

test('launchProvider reuses idle live connections across channel remaps', async () => {
  const { session, calls } = makeSession();
  const oldConn = { alive: true };

  session.connections.set('old-channel', {
    conn: oldConn,
    unsub: () => {
      oldConn.unsubscribed = true;
    },
    conversationId: 'conv-1',
  });
  session._bindConversation('old-channel', 'conv-1');
  session._updateState('idle');

  await session.launchProvider({
    channelId: 'new-channel',
    conversationId: 'conv-1',
    cwd: '/tmp/clawmux-provider-session-test',
  });

  assert.equal(calls.connect.length, 0);
  assert.equal(calls.close.length, 0);
  assert.equal(session.connections.has('old-channel'), false);
  assert.equal(session.connections.has('new-channel'), true);
  assert.equal(session.connections.get('new-channel')?.conversationId, 'conv-1');
});

test('launchProvider reconnects active live connections instead of remapping them', async () => {
  const { session, calls } = makeSession();
  const oldConn = { alive: true };

  session.connections.set('old-channel', {
    conn: oldConn,
    unsub: () => {
      oldConn.unsubscribed = true;
    },
    conversationId: 'conv-1',
  });
  session._bindConversation('old-channel', 'conv-1');
  session._updateState('thinking');

  await session.launchProvider({
    channelId: 'new-channel',
    conversationId: 'conv-1',
    resume: 'resume-abc',
    cwd: '/tmp/clawmux-provider-session-test',
  });

  assert.equal(calls.connect.length, 1);
  assert.equal(calls.connect[0]?.resume, 'resume-abc');
  assert.equal(calls.close.length, 1);
  assert.equal(calls.close[0], oldConn);
  assert.equal(session.connections.has('old-channel'), false);
  assert.equal(session.connections.has('new-channel'), true);
  assert.equal(session.connections.get('new-channel')?.sessionId, 'resume-abc');
});

test('raw provider events are buffered with agent conversation metadata', () => {
  const agentId = 'raw-tail-test';
  clearRawEvents(agentId);
  const { session } = makeSession(agentId);
  session.providerName = 'codex';

  session.connections.set('channel-1', {
    conn: { alive: true, threadId: 'thr_123' },
    unsub: () => {},
    sessionId: 'thr_123',
    conversationId: 'conv-123',
  });
  session._bindConversation('channel-1', 'conv-123');

  session._handleProviderEvent('channel-1', {
    type: 'raw_event',
    direction: 'in',
    transport: 'ws',
    raw: '{"method":"turn/started"}',
    payload: { method: 'turn/started' },
  });

  const events = getRawEvents(agentId, 1);
  assert.equal(events.length, 1);
  assert.equal(events[0].agentId, agentId);
  assert.equal(events[0].backend, 'codex');
  assert.equal(events[0].conversationId, 'conv-123');
  assert.equal(events[0].sessionId, 'thr_123');
  assert.equal(events[0].summary, 'turn/started');
});


test('replay journal replays only unseen events for the same conversation', () => {
  const { session } = makeSession();

  session.connections.set('channel-1', {
    conn: { alive: true },
    unsub: () => {},
    conversationId: 'conv-1',
  });
  session._bindConversation('channel-1', 'conv-1');

  session.send({
    type: 'io_message',
    channelId: 'channel-1',
    message: { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'first' }] } },
  });
  session.send({
    type: 'io_message',
    channelId: 'channel-1',
    message: { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'second' }] } },
  });

  const delivered = [];
  const fn = {
    _sendDirect: (msg) => delivered.push(msg),
    _resume: () => {},
  };

  session._replayToSendFn(fn, {
    conversationId: 'conv-1',
    channelId: 'channel-2',
    replayAfterSeq: 1,
  });

  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].channelId, 'channel-2');
  assert.equal(delivered[0].conversationId, 'conv-1');
  assert.equal(delivered[0].replaySeq, 2);
  assert.equal(delivered[0].message.message.content[0].text, 'second');
});

test('history reload suppresses replay for events already covered by persisted history', () => {
  const { session } = makeSession();

  session.connections.set('channel-1', {
    conn: { alive: true },
    unsub: () => {},
    conversationId: 'conv-1',
  });
  session._bindConversation('channel-1', 'conv-1');

  session.send({
    type: 'io_message',
    channelId: 'channel-1',
    message: { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'persisted' }] } },
  });
  session._markConversationPersisted('conv-1');
  session.send({
    type: 'io_message',
    channelId: 'channel-1',
    message: { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'live-tail' }] } },
  });

  const delivered = [];
  const fn = {
    _sendDirect: (msg) => delivered.push(msg),
    _resume: () => {},
  };

  session._replayToSendFn(fn, {
    conversationId: 'conv-1',
    channelId: 'channel-2',
    replayAfterSeq: 0,
    historyReloaded: true,
  });

  assert.equal(delivered.length, 1);
  assert.equal(delivered[0].replaySeq, 2);
  assert.equal(delivered[0].message.message.content[0].text, 'live-tail');
});
