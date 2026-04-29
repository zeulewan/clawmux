/**
 * Stateless WebSocket client.
 * No stored agent/provider — caller passes agentId explicitly.
 */

// crypto.randomUUID polyfill for non-HTTPS (Tailscale, LAN)
if (typeof crypto !== 'undefined' && typeof crypto.randomUUID !== 'function') {
  crypto.randomUUID = function () {
    const buf = new Uint8Array(16);
    crypto.getRandomValues(buf);
    buf[6] = (buf[6] & 0x0f) | 0x40;
    buf[8] = (buf[8] & 0x3f) | 0x80;
    const h = Array.from(buf, (b) => b.toString(16).padStart(2, '0')).join('');
    return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
  };
}

const WS_URL = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/chat`;
const RECONNECT_BASE = 500;
const RECONNECT_MAX = 15000;
const PING_INTERVAL = 20000;

let ws = null;
let ready = false;
let reconnectDelay = RECONNECT_BASE;
let reconnectTimer = null;
let pingTimer = null;
let pongReceived = true;

// Last switch_agent args — replayed on reconnect
let _lastAgent = '';
let _lastProvider = '';

const pending = [];
const listeners = new Set();

export function onMessage(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Send JSON. Caller is responsible for including agentId. */
export function send(msg) {
  if (ready && ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  } else {
    pending.push(msg);
  }
}

/** Switch agent focus. Replayed on reconnect. */
export function switchAgent(agentId, provider) {
  _lastAgent = agentId || '';
  _lastProvider = provider || '';
  send({ type: 'switch_agent', agentId: _lastAgent, provider: _lastProvider });
  _dispatch({ type: 'agent_switched', agentId: _lastAgent });
}

export function isConnected() {
  return ready;
}

// ── Internals ─────────────────────────────────────────────────

function _connect() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    ready = true;
    pongReceived = true;
    reconnectDelay = RECONNECT_BASE;
    _startPing();
    // Replay last agent switch on reconnect
    if (_lastAgent) {
      ws.send(JSON.stringify({ type: 'switch_agent', agentId: _lastAgent, provider: _lastProvider }));
    }
    _dispatch({ type: 'ws_reconnected' });
    while (pending.length) ws.send(JSON.stringify(pending.shift()));
  };

  ws.onmessage = (event) => {
    if (event.data === '{"type":"ping"}') {
      ws.send('{"type":"pong"}');
      return;
    }
    if (event.data === '{"type":"pong"}') {
      pongReceived = true;
      return;
    }
    // Any message from server means connection is alive
    pongReceived = true;
    try {
      _dispatch(JSON.parse(event.data));
    } catch (err) {
      console.error('[ws] dispatch error:', err);
    }
  };

  ws.onclose = () => {
    ready = false;
    _stopPing();
    _dispatch({ type: 'ws_disconnected' });
    reconnectTimer = setTimeout(_connect, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX);
  };

  ws.onerror = () => {};
}

function _dispatch(msg) {
  for (const fn of listeners) {
    try {
      fn(msg);
    } catch (err) {
      console.error('[ws] listener error:', err);
    }
  }
}

function _startPing() {
  _stopPing();
  pingTimer = setInterval(() => {
    if (ws?.readyState === WebSocket.OPEN) {
      if (!pongReceived) {
        // No pong since last ping — connection is dead, force reconnect
        console.warn('[ws] No pong received — forcing reconnect');
        ws.close();
        return;
      }
      pongReceived = false;
      ws.send('{"type":"ping"}');
    }
  }, PING_INTERVAL);
}

function _stopPing() {
  if (pingTimer) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
}

_connect();
