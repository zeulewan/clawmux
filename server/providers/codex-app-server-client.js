import { spawn as spawnChild } from 'node:child_process';
import { randomUUID } from 'node:crypto';

const DEFAULT_REQUEST_TIMEOUT_MS = 60000;

export class CodexAppServerClient {
  constructor(options = {}) {
    this.command = options.command || 'codex';
    this.args = options.args || ['app-server'];
    this.cwd = options.cwd || process.cwd();
    this.env = options.env || process.env;
    this.spawn = options.spawn || spawnChild;
    this.requestTimeoutMs = options.requestTimeoutMs || DEFAULT_REQUEST_TIMEOUT_MS;
    this.onRaw = options.onRaw || (() => {});
    this.onRequest = options.onRequest || (() => {});
    this.onNotification = options.onNotification || (() => {});
    this.onError = options.onError || (() => {});
    this.onExit = options.onExit || (() => {});

    this.proc = null;
    this.alive = false;
    this.closing = false;
    this.stdoutBuf = '';
    this.pending = new Map();
  }

  start() {
    if (this.proc) return;

    this.proc = this.spawn(this.command, this.args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: process.platform === 'win32',
      detached: process.platform !== 'win32',
    });
    this.alive = true;

    this.proc.stdout.on('data', (chunk) => this._onStdout(chunk));
    this.proc.stderr.on('data', (chunk) => this._onStderr(chunk));
    this.proc.on('error', (err) => {
      this.alive = false;
      this._rejectPending(new Error(`codex app-server process error: ${err.message}`));
      this.onError(err);
    });
    this.proc.on('exit', (code, signal) => {
      this.alive = false;
      const message = `codex app-server exited (code=${code ?? 'null'}, signal=${signal ?? 'null'})`;
      this._rejectPending(new Error(message));
      this.onExit({ code, signal, message, expected: this.closing });
    });
  }

  request(method, params = {}, options = {}) {
    const id = options.id || randomUUID();
    const timeoutMs = options.timeoutMs || this.requestTimeoutMs;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`Timed out waiting for ${method}`));
      }, timeoutMs);
      this.pending.set(String(id), { method, timeout, resolve, reject });
      try {
        this.send({ id, method, params });
      } catch (err) {
        clearTimeout(timeout);
        this.pending.delete(String(id));
        reject(err);
      }
    });
  }

  notify(method, params) {
    this.send(params === undefined ? { method } : { method, params });
  }

  respond(id, result) {
    this.send({ id, result });
  }

  respondError(id, message, code = -32601) {
    this.send({ id, error: { code, message } });
  }

  send(payload) {
    if (!this.proc || !this.alive || !this.proc.stdin.writable) {
      throw new Error('Cannot write to codex app-server stdin');
    }
    const raw = JSON.stringify(payload);
    this.onRaw({
      direction: 'out',
      transport: 'stdio',
      raw,
      payload,
    });
    this.proc.stdin.write(`${raw}\n`);
  }

  close() {
    this.closing = true;
    this.alive = false;
    this._rejectPending(new Error('codex app-server client closed'));
    if (!this.proc) return;

    try {
      if (this.proc.stdin.writable) this.proc.stdin.end();
    } catch {}

    try {
      if (this.proc.pid && process.platform !== 'win32') {
        process.kill(-this.proc.pid, 'SIGTERM');
      } else {
        this.proc.kill('SIGTERM');
      }
    } catch {
      try {
        this.proc.kill('SIGTERM');
      } catch {}
    }
  }

  _onStdout(chunk) {
    this.stdoutBuf += chunk.toString('utf8');
    let nl;
    while ((nl = this.stdoutBuf.indexOf('\n')) !== -1) {
      let line = this.stdoutBuf.slice(0, nl);
      this.stdoutBuf = this.stdoutBuf.slice(nl + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (!line.trim()) continue;
      this._handleLine(line);
    }
  }

  _onStderr(chunk) {
    const raw = chunk.toString('utf8');
    for (const line of raw.split(/\r?\n/g)) {
      const text = line.trim();
      if (!text) continue;
      this.onRaw({
        direction: 'err',
        transport: 'stderr',
        raw: text,
        payload: { type: 'stderr', text },
      });
      this.onError(new Error(text));
    }
  }

  _handleLine(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (err) {
      this.onRaw({
        direction: 'in',
        transport: 'stdio',
        raw,
        payload: { type: 'parse_error', message: err.message },
      });
      this.onError(new Error(`Invalid JSON from codex app-server: ${err.message}`));
      return;
    }

    this.onRaw({
      direction: 'in',
      transport: 'stdio',
      raw,
      payload: msg,
    });

    if (msg && typeof msg === 'object' && msg.method) {
      if (msg.id !== undefined && msg.id !== null) {
        this.onRequest(msg);
      } else {
        this.onNotification(msg);
      }
      return;
    }

    if (msg && typeof msg === 'object' && msg.id !== undefined && msg.id !== null) {
      this._handleResponse(msg);
      return;
    }

    this.onError(new Error('Unrecognized message from codex app-server'));
  }

  _handleResponse(msg) {
    const key = String(msg.id);
    const pending = this.pending.get(key);
    if (!pending) return;

    clearTimeout(pending.timeout);
    this.pending.delete(key);

    if (msg.error) {
      pending.reject(new Error(`${pending.method} failed: ${msg.error.message || JSON.stringify(msg.error)}`));
      return;
    }

    pending.resolve(msg.result);
  }

  _rejectPending(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }
}
