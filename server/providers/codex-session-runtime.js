import { randomUUID } from 'node:crypto';
import { E } from './events.js';
import { CodexAppServerClient } from './codex-app-server-client.js';

const RECOVERABLE_THREAD_RESUME_ERROR_SNIPPETS = [
  'not found',
  'missing thread',
  'no such thread',
  'no rollout found',
  'unknown thread',
  'does not exist',
  'timed out waiting for thread/resume',
];

export function isRecoverableThreadResumeError(error) {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  if (!message.includes('thread/resume')) return false;
  return RECOVERABLE_THREAD_RESUME_ERROR_SNIPPETS.some((snippet) => message.includes(snippet));
}

export class CodexSessionRuntime {
  constructor(provider, config = {}, options = {}) {
    this.provider = provider;
    this.config = { ...config };
    this.command = options.command || 'codex';
    this.clientFactory = options.clientFactory || ((clientOptions) => new CodexAppServerClient(clientOptions));
    this.conn = {
      client: null,
      threadId: null,
      turnId: null,
      listeners: new Set(),
      alive: false,
      cwd: config.cwd,
      model: config.model,
      effortLevel: config.effortLevel || null,
      _pendingApprovals: new Map(),
      _runtime: this,
    };
  }

  async start() {
    const conn = this.conn;
    const client = this.clientFactory({
      command: this.command,
      args: this.provider._serverArgs(),
      cwd: conn.cwd || process.cwd(),
      env: { ...process.env },
      onRaw: (event) => this.provider._emitRaw(conn, event),
      onRequest: (msg) => this.provider._handleMessage(conn, msg),
      onNotification: (msg) => this.provider._handleMessage(conn, msg),
      onError: (err) => {
        if (!this._stderrErrors) this._stderrErrors = new Set();
        const key = err?.message || String(err);
        if (this._stderrErrors.has(key)) return;
        this._stderrErrors.add(key);
        console.error(`[codex-server] ${key}`);
      },
      onExit: ({ message, expected }) => {
        conn.alive = false;
        if (!expected) {
          this.provider._emit(conn, E.sessionClosed(message));
        }
      },
    });

    conn.client = client;
    client.start();
    conn.alive = true;

    try {
      const init = await client.request('initialize', {
        clientInfo: { name: 'ClawMux', version: '1.0.0' },
        capabilities: { experimentalApi: true },
      });
      console.log(`[codex-provider] Connected to ${init?.userAgent || 'codex app-server'}`);
      client.notify('initialized');

      const opened = await this._openThread();
      conn.threadId = opened?.thread?.id || opened?.threadId || conn.threadId;
      if (!conn.threadId) {
        throw new Error('Codex thread open response did not include a thread id');
      }

      console.log(`[codex-provider] Thread ${this.config.resume ? 'resumed' : 'created'}: ${conn.threadId}`);
      if (!this.config.resume) this.provider._writeSessionFile(conn);
      this.provider._emit(conn, E.sessionReady(conn.threadId));
      return conn;
    } catch (err) {
      conn.alive = false;
      try {
        client.close();
      } catch {}
      throw err;
    }
  }

  send(message) {
    const conn = this.conn;
    if (!conn.alive) {
      console.log('[codex-provider] send: not alive');
      return;
    }
    if (!conn.threadId) {
      console.log('[codex-provider] send: no threadId, conn keys:', Object.keys(conn), 'alive:', conn.alive);
      return;
    }

    const id = randomUUID();
    console.log(`[codex-provider] -> turn/start threadId=${conn.threadId} input="${message.slice(0, 50)}"`);
    conn.client
      .request('turn/start', this.provider._turnStartParams(conn, message), { id })
      .then((result) => this.provider._handleMessage(conn, { id, result }))
      .catch((err) => {
        if (!conn.alive) return;
        this.provider._emit(conn, E.turnError(err.message || 'Codex turn/start failed'));
      });
    this.provider._appendToSession(conn, 'user', message);
  }

  respondPermission(requestId, allowed) {
    if (!this.conn.alive) return;
    this.conn.client.respond(requestId, { decision: allowed ? 'accept' : 'deny' });
  }

  interrupt() {
    const conn = this.conn;
    if (!conn.alive || !conn.threadId) return;
    conn.client
      .request('turn/interrupt', {
        threadId: conn.threadId,
        turnId: conn.turnId,
      })
      .catch((err) => {
        if (conn.alive) this.provider._emit(conn, E.turnError(err.message || 'Codex interrupt failed'));
      });
  }

  sendRaw(payload) {
    this.conn.client.send(payload);
  }

  close() {
    this.conn.alive = false;
    try {
      this.conn.client?.close();
    } catch {}
  }

  async _openThread() {
    const conn = this.conn;
    if (!this.config.resume) {
      return await conn.client.request('thread/start', this.provider._threadStartParams(conn));
    }

    try {
      return await conn.client.request('thread/resume', this.provider._threadResumeParams(conn, this.config.resume));
    } catch (err) {
      if (!isRecoverableThreadResumeError(err)) throw err;
      console.log(`[codex-provider] Thread resume failed: ${err.message || 'unknown'}`);
      console.log('[codex-provider] Falling back to a fresh thread');
      this.config.resume = null;
      return await conn.client.request('thread/start', this.provider._threadStartParams(conn));
    }
  }
}
