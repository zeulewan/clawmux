import test from 'node:test';
import assert from 'node:assert/strict';

import ProviderSession from '../server/provider-session.js';

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

function makeSession() {
  const agentProcs = new Map();
  const session = new ProviderSession(() => {}, '/tmp/clawmux-provider-session-test', 'puck', agentProcs);
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
