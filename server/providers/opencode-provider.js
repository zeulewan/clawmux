/**
 * opencode (sst/opencode) provider.
 *
 * Spawns a single shared `opencode serve` daemon on OPENCODE_PORT and routes
 * every ClawMux agent to its own opencode session id within that daemon.
 * Mirror of the codex-provider shared-daemon pattern.
 *
 * Protocol: HTTP + SSE.
 *   POST /session                     → create session, returns { id }
 *   POST /session/{id}/prompt_async   → send message parts, stream events
 *   GET  /event                       → server-wide SSE stream of events
 *   POST /session/{id}/abort          → abort current turn
 *   DELETE /session/{id}              → destroy session
 *
 * Streamed events we care about (observed):
 *   message.part.delta  field=text/reasoning  → text/thinking deltas
 *   message.part.updated type=tool            → tool lifecycle
 *   message.updated     finish=*              → turn end
 *   session.status      status.type=idle|busy → streaming flag
 */

import { spawn } from 'child_process';
import { writeFileSync, appendFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { E } from './events.js';
import { hashProjectPath } from '../sessions.js';

const OPENCODE_CMD = process.env.OPENCODE_CMD || 'opencode';
const OPENCODE_PORT = parseInt(process.env.OPENCODE_PORT || '4499');
const OPENCODE_HOST = process.env.OPENCODE_HOST || '127.0.0.1';

// Single shared daemon across the hub
let _sharedServerProc = null;
let _sharedServerReady = false;
let _sharedServerStarting = null;
// Single global SSE listener multiplexed across connections
let _eventController = null;
const _sessionListeners = new Map(); // sessionId → Set<(ev) => void>

function _baseUrl() {
  return `http://${OPENCODE_HOST}:${OPENCODE_PORT}`;
}

async function _startSharedServer() {
  if (_sharedServerReady) return;
  if (_sharedServerStarting) return _sharedServerStarting;

  // Check if already running on this port
  try {
    const res = await fetch(`${_baseUrl()}/global/health`);
    if (res.ok) {
      console.log(`[opencode-provider] Server already running on port ${OPENCODE_PORT}`);
      _sharedServerReady = true;
      return;
    }
  } catch {}

  _sharedServerStarting = new Promise((resolve, reject) => {
    const proc = spawn(OPENCODE_CMD, ['serve', '--port', String(OPENCODE_PORT), '--hostname', OPENCODE_HOST], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env },
    });
    _sharedServerProc = proc;

    let resolved = false;
    const settle = (ok, err) => {
      if (resolved) return;
      resolved = true;
      if (ok) {
        _sharedServerReady = true;
        resolve();
      } else {
        _sharedServerStarting = null;
        reject(err);
      }
    };

    // Ready-check by polling health
    const start = Date.now();
    const poll = async () => {
      if (Date.now() - start > 30_000) return settle(false, new Error('opencode serve ready timeout'));
      try {
        const res = await fetch(`${_baseUrl()}/global/health`);
        if (res.ok) return settle(true);
      } catch {}
      setTimeout(poll, 250);
    };
    poll();

    proc.stderr.on('data', (d) => {
      const t = d.toString().trim();
      if (t) console.error(`[opencode-serve] ${t}`);
    });

    proc.on('exit', (code, signal) => {
      _sharedServerReady = false;
      _sharedServerProc = null;
      _sharedServerStarting = null;
      if (_eventController) {
        try {
          _eventController.abort();
        } catch {}
        _eventController = null;
      }
      console.error(`[opencode-serve] exited code=${code} signal=${signal}`);
    });

    proc.on('error', (err) => settle(false, err));
  });

  return _sharedServerStarting;
}

async function _ensureEventStream() {
  if (_eventController && !_eventController.signal.aborted) return;
  _eventController = new AbortController();
  const res = await fetch(`${_baseUrl()}/event`, {
    signal: _eventController.signal,
    headers: { accept: 'text/event-stream' },
  });
  if (!res.ok || !res.body) {
    console.error(`[opencode-provider] /event subscribe failed: ${res.status}`);
    return;
  }
  // Don't await — pump in background
  (async () => {
    const reader = res.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buf = '';
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        // SSE records are separated by \n\n
        let idx;
        while ((idx = buf.indexOf('\n\n')) !== -1) {
          const record = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          _dispatchSse(record);
        }
      }
    } catch (err) {
      if (err.name !== 'AbortError') {
        console.error(`[opencode-provider] event stream error: ${err.message}`);
      }
    }
  })();
}

function _dispatchSse(record) {
  // Records look like: data: {...}\n(optionally data: ...)
  const lines = record.split('\n');
  const jsonLine = lines.find((l) => l.startsWith('data:'));
  if (!jsonLine) return;
  const payload = jsonLine.slice(5).trim();
  if (!payload) return;
  let ev;
  try {
    ev = JSON.parse(payload);
  } catch {
    return;
  }
  const sessionId = _extractSessionId(ev);
  if (!sessionId) return;
  const listeners = _sessionListeners.get(sessionId);
  if (!listeners) return;
  for (const fn of listeners) {
    try {
      fn(ev);
    } catch (err) {
      console.error(`[opencode-provider] listener error: ${err.message}`);
    }
  }
}

function _extractSessionId(ev) {
  const p = ev.properties;
  if (!p) return null;
  return p.sessionID || p.info?.sessionID || p.info?.id || p.part?.sessionID || null;
}

export class OpenCodeProvider {
  constructor() {
    this.name = 'opencode';
  }

  /**
   * Connect: ensure shared daemon running, create session, subscribe to events.
   * @param {object} config - { cwd, model, resume }
   */
  async connect(config = {}) {
    await _startSharedServer();
    await _ensureEventStream();

    let sessionId;
    if (config.resume) {
      sessionId = config.resume;
    } else {
      const res = await fetch(`${_baseUrl()}/session`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          directory: config.cwd || process.cwd(),
        }),
      });
      if (!res.ok) throw new Error(`opencode session create failed: ${res.status}`);
      const data = await res.json();
      sessionId = data.id;
    }

    const conn = {
      sessionId,
      cwd: config.cwd || process.cwd(),
      model: config.model || null,
      effortLevel: config.effortLevel || null,
      listeners: new Set(),
      alive: true,
      _toolByPartId: new Map(), // partId → { callID, tool, lastStatus }
      _reasoningPartIds: new Set(), // partIds that are reasoning type
    };

    const dispatch = (ev) => {
      this._emitRaw(conn, {
        direction: 'in',
        transport: 'sse',
        raw: JSON.stringify(ev),
        payload: ev,
      });
      this._handleEvent(conn, ev);
    };
    if (!_sessionListeners.has(sessionId)) _sessionListeners.set(sessionId, new Set());
    _sessionListeners.get(sessionId).add(dispatch);
    conn._unsubscribe = () => {
      const set = _sessionListeners.get(sessionId);
      if (set) {
        set.delete(dispatch);
        if (set.size === 0) _sessionListeners.delete(sessionId);
      }
    };

    // Write session file so history can be loaded on resume
    if (!config.resume) this._writeSessionMeta(conn);

    // Emit session_ready once the caller is subscribed
    queueMicrotask(() => this._emit(conn, E.sessionReady(sessionId)));

    return conn;
  }

  /**
   * Send a user message via prompt_async (fire-and-forget; events arrive via SSE).
   */
  async send(conn, message) {
    if (!conn.alive) return;
    this._appendToSession(conn, 'user', message);
    const body = { parts: [{ type: 'text', text: message }] };
    if (conn.model && typeof conn.model === 'string' && conn.model.includes('/')) {
      const [providerID, modelID] = conn.model.split('/');
      body.model = { providerID, modelID };
    }
    if (conn.effortLevel && conn.effortLevel !== 'default') {
      body.variant = conn.effortLevel;
    }
    try {
      this._emitRaw(conn, {
        direction: 'out',
        transport: 'http',
        raw: JSON.stringify(body),
        payload: body,
        summary: 'prompt_async',
      });
      const res = await fetch(`${_baseUrl()}/session/${conn.sessionId}/prompt_async`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        if (res.status === 400 || res.status === 404) {
          // Stale session — trigger resume retry
          this._emit(conn, { type: 'resume_failed' });
        } else {
          this._emit(conn, E.turnError(`opencode prompt_async failed: ${res.status}`));
        }
      }
    } catch (err) {
      this._emit(conn, E.turnError(`opencode send error: ${err.message}`));
    }
  }

  async interrupt(conn) {
    if (!conn.alive) return;
    try {
      this._emitRaw(conn, {
        direction: 'out',
        transport: 'http',
        raw: JSON.stringify({ sessionId: conn.sessionId, action: 'abort' }),
        payload: { sessionId: conn.sessionId, action: 'abort' },
        summary: 'abort',
      });
      await fetch(`${_baseUrl()}/session/${conn.sessionId}/abort`, { method: 'POST' });
    } catch {}
  }

  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  /**
   * Permission responses are handled internally via permission.asked →
   * auto-approve. Session-layer calls are a no-op.
   */
  respondPermission(_conn, _requestId, _allowed) {
    // no-op
  }

  async close(conn) {
    if (!conn.alive) return;
    conn.alive = false;
    if (conn._unsubscribe) conn._unsubscribe();
    this._emit(conn, E.sessionClosed('normal'));
  }

  // ── internals ──────────────────────────────────────────────────────────

  _handleEvent(conn, ev) {
    const t = ev.type;
    const p = ev.properties || {};

    switch (t) {
      case 'session.status': {
        const status = p.status?.type;
        if (status === 'busy' && !conn._turnActive) {
          conn._turnActive = true;
          this._emit(conn, E.turnStart());
        } else if (status === 'idle' && conn._turnActive) {
          conn._turnActive = false;
          this._emit(conn, E.turnComplete({}));
        }
        break;
      }

      case 'message.part.delta': {
        // incremental text/reasoning chunks on a part
        const field = p.field;
        const delta = p.delta;
        if (!delta) break;
        // OpenCode sends reasoning content as field=text on reasoning parts.
        // Check partID to determine the real type.
        const isReasoning = conn._reasoningPartIds.has(p.partID) || field === 'reasoning';
        if (isReasoning) this._emit(conn, E.thinkingDelta(delta));
        else if (field === 'text') this._emit(conn, E.textDelta(delta));
        break;
      }

      case 'message.part.updated': {
        const part = p.part;
        if (!part) break;
        // Track reasoning parts so their deltas get reclassified
        if (part.type === 'reasoning') conn._reasoningPartIds.add(part.id);
        this._handlePart(conn, part);
        break;
      }

      case 'message.updated': {
        const info = p.info;
        // Only emit turnComplete for assistant messages with a finish reason,
        // and only once per turn (deduplicate multiple message.updated events)
        if (info?.finish && info?.role === 'assistant' && conn._turnActive) {
          conn._turnActive = false;
          this._emit(
            conn,
            E.turnComplete({
              input: info.tokens?.input || 0,
              output: info.tokens?.output || 0,
              reasoning: info.tokens?.reasoning || 0,
              cacheRead: info.tokens?.cache?.read || 0,
              cacheWrite: info.tokens?.cache?.write || 0,
            }),
          );
        }
        break;
      }

      case 'permission.asked': {
        // Auto-approve with "always" so future same-pattern requests don't stall.
        // Matches the auto-approve behavior of claude/codex providers.
        const permId = p.id;
        const sessId = p.sessionID;
        if (permId && sessId) this._approvePermission(conn, sessId, permId);
        break;
      }

      default:
        // session.updated, session.diff, session.idle, server.connected — ignore
        break;
    }
  }

  async _approvePermission(conn, sessionId, permissionId) {
    const body = { response: 'always' };
    try {
      this._emitRaw(conn, {
        direction: 'out',
        transport: 'http',
        raw: JSON.stringify(body),
        payload: body,
        summary: `permission:${permissionId}`,
      });
      await fetch(`${_baseUrl()}/session/${sessionId}/permissions/${permissionId}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
      });
    } catch (err) {
      console.error(`[opencode-provider] permission approval failed: ${err.message}`);
    }
  }

  _handlePart(conn, part) {
    if (part.type === 'tool') {
      const prev = conn._toolByPartId.get(part.id);
      const status = part.state?.status;

      if (!prev && (status === 'pending' || status === 'running')) {
        this._emit(conn, E.toolStart(part.callID, part.tool, part.state?.input || {}));
        conn._toolByPartId.set(part.id, { callID: part.callID, tool: part.tool, lastStatus: status });
      } else if (prev) {
        prev.lastStatus = status;
      }

      if (status === 'completed') {
        const output = part.state?.output || part.state?.metadata?.output || '';
        const isError = (part.state?.metadata?.exit ?? 0) !== 0;
        this._emit(
          conn,
          E.toolResult(part.callID, typeof output === 'string' ? output : JSON.stringify(output), isError),
        );
        conn._toolByPartId.delete(part.id);
      }
    } else if (part.type === 'text' && part.text && part.time?.end) {
      // Assistant session writes handled by provider-session at turn_complete
    } else if (part.type === 'reasoning' && part.time?.end) {
      this._emit(conn, E.thinkingDone(part.text || ''));
      conn._reasoningPartIds.delete(part.id);
    }
  }

  _getSessionPath(conn) {
    const CLAUDE_PROJECTS_DIR = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
    const hashed = hashProjectPath(conn.cwd);
    const dir = join(CLAUDE_PROJECTS_DIR, hashed);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    return join(dir, `${conn.sessionId}.jsonl`);
  }

  _writeSessionMeta(conn) {
    try {
      const path = this._getSessionPath(conn);
      const entry = JSON.stringify({
        type: 'session_meta',
        provider: 'opencode',
        sessionId: conn.sessionId,
        timestamp: new Date().toISOString(),
      });
      writeFileSync(path, entry + '\n');
    } catch {}
  }

  _appendToSession(conn, role, text) {
    try {
      const path = this._getSessionPath(conn);
      const entry = JSON.stringify({
        type: role,
        message: { role, content: [{ type: 'text', text }] },
        timestamp: new Date().toISOString(),
      });
      appendFileSync(path, entry + '\n');
    } catch {}
  }

  _emit(conn, event) {
    for (const listener of conn.listeners) {
      try {
        listener(event);
      } catch (err) {
        console.error(`[opencode-provider] listener error: ${err.message}`);
      }
    }
  }

  _emitRaw(conn, event) {
    this._emit(conn, E.rawEvent(event));
  }
}
