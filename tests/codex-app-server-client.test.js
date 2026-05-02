import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';

import { CodexAppServerClient } from '../server/providers/codex-app-server-client.js';

function createFakeChild() {
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.kill = () => {
    child.killed = true;
    child.emit('exit', null, 'SIGTERM');
  };
  return child;
}

test('codex app-server client sends JSON-RPC requests and resolves responses', async () => {
  const child = createFakeChild();
  const writes = [];
  const rawEvents = [];
  child.stdin.on('data', (chunk) => writes.push(...chunk.toString('utf8').trim().split('\n')));

  const client = new CodexAppServerClient({
    spawn: () => child,
    onRaw: (event) => rawEvents.push(event),
  });

  client.start();
  const response = client.request('model/list', {});
  assert.equal(writes.length, 1);
  const request = JSON.parse(writes[0]);
  assert.equal(request.method, 'model/list');

  child.stdout.write(`${JSON.stringify({ id: request.id, result: { data: [{ id: 'gpt-test' }] } })}\n`);

  assert.deepEqual(await response, { data: [{ id: 'gpt-test' }] });
  assert.equal(rawEvents[0].direction, 'out');
  assert.equal(rawEvents[1].direction, 'in');
  client.close();
});

test('codex app-server client dispatches server requests and notifications', () => {
  const child = createFakeChild();
  const requests = [];
  const notifications = [];
  const client = new CodexAppServerClient({
    spawn: () => child,
    onRequest: (msg) => requests.push(msg),
    onNotification: (msg) => notifications.push(msg),
  });

  client.start();
  child.stdout.write(`${JSON.stringify({ id: 0, method: 'item/tool/requestUserInput', params: { questions: [] } })}\n`);
  child.stdout.write(`${JSON.stringify({ method: 'turn/completed', params: { usage: {} } })}\n`);

  assert.equal(requests.length, 1);
  assert.equal(requests[0].id, 0);
  assert.equal(requests[0].method, 'item/tool/requestUserInput');
  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].method, 'turn/completed');
  client.close();
});
