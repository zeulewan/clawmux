/**
 * Codex App Server provider.
 *
 * Connects via WebSocket to `codex app-server --listen ws://127.0.0.1:{port}`.
 * Translates JSON-RPC notifications into internal events.
 *
 * Tool execution: App-server handles it internally.
 * Permission flow: Server sends requestApproval, we auto-approve.
 */

import { spawn, execSync } from 'child_process';
import { WebSocket } from 'ws';
import { writeFileSync, appendFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { E } from './events.js';
import { hashProjectPath } from '../sessions.js';

const CODEX_CMD = process.env.CODEX_CMD || 'codex';
const CODEX_PORT = parseInt(process.env.CODEX_PORT || '4500');

/**
 * Discover available models by querying the codex app-server via model/list RPC.
 * Requires the app-server to be running. Returns null if not available.
 */
export async function discoverCodexModels() {
  try {
    // Check if server is running
    const health = await fetch(`http://127.0.0.1:${CODEX_PORT}/readyz`);
    if (!health.ok) return null;
  } catch {
    return null;
  }

  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://127.0.0.1:${CODEX_PORT}`);
    const timeout = setTimeout(() => { ws.close(); resolve(null); }, 10000);

    ws.on('open', () => {
      ws.send(JSON.stringify({
        id: 'init-discover',
        method: 'initialize',
        params: { clientInfo: { name: 'ClawMux-discover', version: '1.0.0' }, capabilities: {} },
      }));
    });

    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.id === 'init-discover' && msg.result) {
        ws.send(JSON.stringify({ id: 'list-models', method: 'model/list', params: {} }));
      }
      if (msg.id === 'list-models' && msg.result) {
        clearTimeout(timeout);
        const raw = msg.result.data || msg.result.models || [];
        const models = raw
          .filter((m) => !m.hidden)
          .map((m) => ({
            id: m.id || m.model,
            label: m.displayName || m.id,
            contextWindow: m.contextWindow || 272000,
          }));
        ws.close();
        resolve(models);
      }
    });

    ws.on('error', () => { clearTimeout(timeout); resolve(null); });
  });
}

// Single shared app-server across all connections
let _sharedServerProc = null;
let _sharedServerReady = false;
let _sharedServerStarting = null;

export class CodexProvider {
  constructor() {
    this.name = 'codex';
  }

  /**
   * Connect: start app-server if needed, then connect via WebSocket.
   * @param {object} config - { cwd, model, resume }
   * @returns {Promise<object>} connection
   */
  async connect(config = {}) {
    // Start shared app-server if not running
    await this._ensureServer(config.cwd);

    const ws = new WebSocket(`ws://127.0.0.1:${CODEX_PORT}`);
    const conn = {
      ws,
      threadId: null,
      turnId: null,
      listeners: new Set(),
      alive: false,
      cwd: config.cwd,
      model: config.model,
      effortLevel: config.effortLevel || null,
      _pendingApprovals: new Map(),
    };

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Codex WebSocket connect timeout')), 10000);
      const startNewThread = () => {
        conn._threadCreateId = crypto.randomUUID();
        ws.send(
          JSON.stringify({
            id: conn._threadCreateId,
            method: 'thread/start',
            params: { cwd: conn.cwd || undefined },
          }),
        );
      };

      ws.on('open', async () => {
        conn.alive = true;
        clearTimeout(timeout);

        // Send initialize handshake
        conn._initId = crypto.randomUUID();
        ws.send(
          JSON.stringify({
            id: conn._initId,
            method: 'initialize',
            params: {
              clientInfo: { name: 'ClawMux', version: '1.0.0' },
              capabilities: {},
            },
          }),
        );
      });

      ws.on('message', (data) => {
        try {
          const msg = JSON.parse(data.toString());
          // Handle init response
          if (msg.id === conn._initId && msg.result) {
            console.log(`[codex-provider] Connected to ${msg.result.userAgent}`);
            if (config.resume) {
              // Resume existing thread
              conn._threadCreateId = crypto.randomUUID();
              ws.send(
                JSON.stringify({
                  id: conn._threadCreateId,
                  method: 'thread/resume',
                  params: { threadId: config.resume, cwd: conn.cwd || undefined, persistExtendedHistory: false },
                }),
              );
            } else {
              // Create new thread
              startNewThread();
            }
            return;
          }
          // Handle thread/start or thread/resume response
          if (msg.id === conn._threadCreateId && msg.result?.thread?.id) {
            conn.threadId = msg.result.thread.id;
            console.log(`[codex-provider] Thread ${config.resume ? 'resumed' : 'created'}: ${conn.threadId}`);
            if (!config.resume) this._writeSessionFile(conn);
            this._emit(conn, E.sessionReady(conn.threadId));
            resolve(conn);
            return;
          }
          // Handle thread/resume error (stale thread)
          if (msg.id === conn._threadCreateId && msg.error) {
            console.log(`[codex-provider] Thread resume failed: ${msg.error.message || 'unknown'}`);
            if (config.resume) {
              console.log('[codex-provider] Falling back to a fresh thread');
              config.resume = null;
              startNewThread();
            } else {
              this._emit(conn, { type: 'resume_failed' });
              resolve(conn);
            }
            return;
          }
          this._handleMessage(conn, msg);
        } catch (err) {
          console.error('[codex-provider] Parse error:', err.message);
        }
      });

      ws.on('close', () => {
        conn.alive = false;
        this._emit(conn, E.sessionClosed('WebSocket closed'));
      });

      ws.on('error', (err) => {
        conn.alive = false;
        clearTimeout(timeout);
        reject(err);
      });
    });
  }

  /**
   * Send a user message — starts a new turn.
   */
  send(conn, message) {
    if (!conn.alive) {
      console.log('[codex-provider] send: not alive');
      return;
    }
    if (!conn.threadId) {
      console.log('[codex-provider] send: no threadId, conn keys:', Object.keys(conn), 'alive:', conn.alive);
      return;
    }
    const turnId = crypto.randomUUID();
    const payload = {
      id: turnId,
      method: 'turn/start',
      params: {
        threadId: conn.threadId,
        input: [{ type: 'text', text: message }],
        effort: conn.effortLevel || undefined,
      },
    };
    console.log(`[codex-provider] → turn/start threadId=${conn.threadId} input="${message.slice(0, 50)}"`);
    conn.ws.send(JSON.stringify(payload));
    this._appendToSession(conn, 'user', message);
    // Don't emit turnStart here — the server will send turn/started notification
  }

  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  respondPermission(conn, requestId, allowed) {
    if (!conn.alive) return;
    conn.ws.send(
      JSON.stringify({
        id: requestId,
        result: { decision: allowed ? 'accept' : 'deny' },
      }),
    );
  }

  interrupt(conn) {
    if (!conn.alive) return;
    conn.ws.send(
      JSON.stringify({
        id: crypto.randomUUID(),
        method: 'turn/interrupt',
        params: {
          threadId: conn.threadId,
          turnId: conn.turnId,
        },
      }),
    );
  }

  close(conn) {
    conn.alive = false;
    try {
      conn.ws.close();
    } catch {}
  }

  /**
   * Shut down the shared app-server process.
   */
  shutdown() {
    if (_sharedServerProc && !_sharedServerProc.killed) {
      _sharedServerProc.kill('SIGTERM');
      _sharedServerProc = null;
      _sharedServerReady = false;
      _sharedServerStarting = null;
    }
  }

  // ── Internal ──

  /** Kill whatever process is listening on a given port. */
  _killPortProcess(port) {
    try {
      // Try lsof (macOS + most Linux)
      const lines = execSync(`lsof -ti:${port} 2>/dev/null`, { encoding: 'utf8' }).trim().split('\n');
      for (const pid of lines) {
        if (pid) try { process.kill(parseInt(pid), 'SIGTERM'); } catch {}
      }
    } catch {
      // Fallback: ss + /proc (Linux without lsof)
      try {
        const out = execSync(`ss -tlnp sport = :${port} 2>/dev/null`, { encoding: 'utf8' });
        const pidRe = /pid=(\d+)/g;
        let m;
        while ((m = pidRe.exec(out)) !== null) {
          try { process.kill(parseInt(m[1]), 'SIGTERM'); } catch {}
        }
      } catch {}
    }
  }

  async _ensureServer(cwd) {
    // Already running
    if (_sharedServerReady && _sharedServerProc && !_sharedServerProc.killed) return;

    // Already starting (another connect() is waiting)
    if (_sharedServerStarting) return _sharedServerStarting;

    _sharedServerStarting = this._startServer(cwd);
    await _sharedServerStarting;
    _sharedServerStarting = null;
  }

  async _startServer(cwd) {
    const listenUrl = `ws://127.0.0.1:${CODEX_PORT}`;

    // Check if something is already running on this port
    try {
      const r = await fetch(`http://127.0.0.1:${CODEX_PORT}/readyz`);
      if (r.ok) {
        // Verify it actually accepts WebSocket connections (not just a stale HTTP listener)
        const alive = await new Promise((resolve) => {
          const ws = new WebSocket(listenUrl);
          const timer = setTimeout(() => { try { ws.close(); } catch {} resolve(false); }, 3000);
          ws.on('open', () => { clearTimeout(timer); ws.close(); resolve(true); });
          ws.on('error', () => { clearTimeout(timer); resolve(false); });
        });
        if (alive) {
          console.log(`[codex-provider] App-server already running on port ${CODEX_PORT} (verified)`);
          _sharedServerReady = true;
          return;
        }
        // Stale process — kill it
        console.warn(`[codex-provider] Stale process on port ${CODEX_PORT} (readyz OK but WS dead) — killing`);
        this._killPortProcess(CODEX_PORT);
        await new Promise((r) => setTimeout(r, 500));
      }
    } catch {}

    console.log(`[codex-provider] Starting app-server on ${listenUrl}`);

    _sharedServerProc = spawn(
      CODEX_CMD,
      ['app-server', '--listen', listenUrl, '-c', 'sandbox_mode="danger-full-access"'],
      {
        stdio: ['pipe', 'pipe', 'pipe'],
        cwd: cwd || process.cwd(),
        env: { ...process.env },
      },
    );

    _sharedServerProc.stderr.on('data', (d) => {
      const t = d.toString().trim();
      if (t) console.error(`[codex-server] ${t}`);
    });

    _sharedServerProc.on('exit', (code) => {
      console.error(`[codex-provider] App-server exited (code ${code}) — will restart on next connect`);
      _sharedServerProc = null;
      _sharedServerReady = false;
      _sharedServerStarting = null;
    });

    // Wait for server to be ready
    await new Promise((resolve, reject) => {
      let attempts = 0;
      const check = () => {
        attempts++;
        if (attempts > 30) {
          reject(new Error('Codex app-server failed to start'));
          return;
        }
        const ws = new WebSocket(listenUrl);
        ws.on('open', () => {
          ws.close();
          _sharedServerReady = true;
          resolve();
        });
        ws.on('error', () => setTimeout(check, 300));
      };
      setTimeout(check, 500);
    });
  }

  _getSessionPath(conn) {
    const CLAUDE_PROJECTS_DIR = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
    const hashed = hashProjectPath(conn.cwd || process.cwd());
    const dir = join(CLAUDE_PROJECTS_DIR, hashed);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    return join(dir, `${conn.threadId}.jsonl`);
  }

  _writeSessionFile(conn) {
    if (!conn.threadId || !conn.cwd) return;
    try {
      const path = this._getSessionPath(conn);
      const entry = JSON.stringify({
        type: 'session_meta',
        provider: 'codex',
        threadId: conn.threadId,
        timestamp: new Date().toISOString(),
      });
      writeFileSync(path, entry + '\n');
    } catch (err) {
      console.error('[codex-provider] Failed to write session file:', err.message);
    }
  }

  _appendToSession(conn, role, text) {
    if (!conn.threadId || !conn.cwd) return;
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
    for (const fn of conn.listeners) fn(event);
  }

  _handleMessage(conn, msg) {
    // JSON-RPC notification or server request (has method)
    if (msg.method) {
      console.debug(`[codex-provider] ← ${msg.method}${msg.id ? ' (request)' : ''}`);
      this._handleNotification(conn, msg.method, msg.params || {}, msg.id);
      return;
    }

    // JSON-RPC response (has id)
    if (msg.id && msg.result) {
      // turn/start response — emit turnStart here as Codex doesn't always send turn/started notification
      if (msg.result.turn) {
        if (msg.result.turn.threadId) conn.threadId = msg.result.turn.threadId;
        conn.turnId = msg.result.turn.id;
        // Guard: emit once per turn (turn/started notification may also arrive)
        if (conn._turnStartEmitted !== conn.turnId) {
          conn._turnStartEmitted = conn.turnId;
          this._emit(conn, E.turnStart());
        }
      }
    }

    // JSON-RPC error
    if (msg.id && msg.error) {
      this._emit(conn, E.turnError(msg.error.message || 'Codex error'));
    }
  }

  _handleNotification(conn, method, params, msgId) {
    switch (method) {
      case 'thread/started':
        if (params.thread?.id) conn.threadId = params.thread.id;
        break;

      case 'turn/started':
        if (params.turn?.id) conn.turnId = params.turn.id;
        // Guard: emit once per turn (RPC response may have already emitted it)
        if (conn._turnStartEmitted !== conn.turnId) {
          conn._turnStartEmitted = conn.turnId;
          this._emit(conn, E.turnStart());
        }
        break;

      case 'item/agentMessage/delta':
        if (params.delta != null) {
          this._emit(conn, E.textDelta(params.delta));
        }
        break;

      case 'item/commandExecution/outputDelta':
        if (params.delta != null) {
          this._emit(conn, E.commandOutput(params.itemId || params.id || '', params.delta));
        }
        break;

      case 'item/started': {
        const item = params.item;
        if (!item) break;
        if (item.type === 'commandExecution') {
          const cmd = item.command || '';
          const shortCmd = cmd.includes("'") ? cmd.split("'").slice(1, -1).join("'") : cmd;
          this._emit(conn, E.commandStart(item.id, shortCmd || cmd));
        } else if (item.type === 'webSearch') {
          this._emit(conn, E.toolStart(item.id, 'WebSearch', { query: item.query || '' }));
        } else if (item.type === 'fileChange') {
          const changes = item.changes || [];
          for (const c of changes) {
            this._emit(conn, E.fileChange(c.path, c.kind?.type || 'edit', c.diff));
          }
        } else if (item.type === 'reasoning') {
          // Only open thinking block if content will follow — Codex often
          // sends empty reasoning blocks (content hidden by API). We track
          // the reasoning ID and emit thinkingDelta lazily on first real delta.
          conn._pendingReasoning = item.id;
        }
        break;
      }

      case 'item/fileChange/outputDelta':
        if (params.delta) {
          this._emit(conn, E.textDelta(params.delta));
        }
        break;

      case 'item/reasoning/textDelta':
        if (params.delta != null) {
          if (conn._pendingReasoning) {
            this._emit(conn, E.thinkingDelta(''));
            conn._pendingReasoning = null;
          }
          this._emit(conn, E.thinkingDelta(params.delta));
        }
        break;

      case 'item/reasoning/summaryTextDelta':
        if (params.delta != null) {
          if (conn._pendingReasoning) {
            this._emit(conn, E.thinkingDelta(''));
            conn._pendingReasoning = null;
          }
          this._emit(conn, E.thinkingDelta(params.delta));
        }
        break;

      case 'item/reasoning/summaryPartAdded':
        // Part added to reasoning summary — content arrives via summaryTextDelta
        break;

      case 'item/plan/delta':
        // Planner streaming text — surface as thinking (planning is reasoning)
        if (params.delta != null) {
          if (conn._pendingReasoning) {
            this._emit(conn, E.thinkingDelta(''));
            conn._pendingReasoning = null;
          }
          this._emit(conn, E.thinkingDelta(params.delta));
        }
        break;

      case 'turn/plan/updated':
        // Full plan state update — informational, deltas handled above
        break;

      case 'command/exec/outputDelta':
        // Newer variant of command output delta
        if (params.delta != null) {
          this._emit(conn, E.commandOutput(params.itemId || params.id || '', params.delta));
        }
        break;

      case 'item/commandExecution/terminalInteraction':
        // Interactive terminal prompt — auto-respond empty (we can't interact)
        if (msgId) {
          console.warn(`[codex-provider] Terminal interaction requested — auto-sending empty response`);
          conn.ws.send(JSON.stringify({ id: msgId, result: { input: '' } }));
        }
        break;

      case 'item/mcpToolCall/progress':
        // MCP tool execution progress — surface as command output
        if (params.progress != null) {
          this._emit(
            conn,
            E.commandOutput(
              params.itemId || '',
              typeof params.progress === 'string' ? params.progress : JSON.stringify(params.progress),
            ),
          );
        }
        break;

      case 'error':
        this._emit(conn, E.turnError(params.message || params.error || 'Codex server error'));
        break;

      case 'thread/closed':
        this._emit(conn, E.sessionClosed('thread closed'));
        break;

      case 'turn/diff/updated':
        // Git-style diff of all file changes in this turn — informational
        break;

      case 'item/completed': {
        const item = params.item;
        if (!item) break;
        switch (item.type) {
          case 'agentMessage':
            this._emit(conn, E.textDone(item.text || ''));
            // Assistant session writes handled by provider-session at turn_complete
            break;
          case 'reasoning':
            if (!conn._pendingReasoning) {
              // Only close if we actually opened a thinking block
              this._emit(conn, E.thinkingDone(item.text || item.summary?.join?.('') || ''));
            }
            conn._pendingReasoning = null;
            break;
          case 'commandExecution': {
            // aggregatedOutput can be a string or { text: string }
            const output =
              typeof item.aggregatedOutput === 'string'
                ? item.aggregatedOutput
                : item.aggregatedOutput?.text ||
                  (typeof item.stdout === 'string' ? item.stdout : item.stdout?.text) ||
                  '';
            if (output) this._emit(conn, E.commandOutput(item.id, output));
            this._emit(conn, E.commandDone(item.id, item.exitCode ?? item.exit_code ?? 0));
            break;
          }
          case 'fileChange':
            if (item.changes) {
              for (const change of item.changes) {
                this._emit(conn, E.fileChange(change.path, change.kind || 'edit', change.diff));
              }
            }
            break;
          case 'webSearch': {
            const action = item.action || {};
            const query = item.query || action.query || '';
            const url = action.url || '';
            const result = query
              ? `Searched: ${query}` + (url ? `\nURL: ${url}` : '')
              : url
                ? `Opened: ${url}`
                : 'Web search';
            this._emit(conn, E.toolResult(item.id, result, false));
            break;
          }
          case 'mcpToolCall':
            this._emit(conn, E.toolResult(item.id, item.result || '', !!item.error));
            break;
        }
        break;
      }

      case 'item/commandExecution/requestApproval':
      case 'item/fileChange/requestApproval':
      case 'item/permissions/requestApproval': {
        // Auto-approve — use the JSON-RPC message ID (server request), not params
        const reqId = msgId || params.requestId || params.id;
        console.log(`[codex-provider] Auto-approving ${method} (id=${reqId})`);
        if (reqId) this.respondPermission(conn, reqId, true);
        break;
      }

      case 'turn/completed': {
        const usage = params.turn?.usage || params.usage;
        const mapped = usage
          ? {
              inputTokens: usage.inputTokens || usage.input_tokens,
              outputTokens: usage.outputTokens || usage.output_tokens,
            }
          : undefined;
        this._emit(conn, E.turnComplete(mapped));
        break;
      }

      case 'turn/failed':
        this._emit(conn, E.turnError(params.turn?.error?.message || params.error?.message || 'Turn failed'));
        break;

      case 'thread/tokenUsage/updated': {
        const tu = params.tokenUsage || {};
        const ctx = tu.modelContextWindow || 0;
        const used = tu.last?.totalTokens || 0;
        if (ctx > 0) {
          this._emit(
            conn,
            E.usageUpdate({
              contextPercent: Math.max(0, Math.min(100, Math.round((used / ctx) * 100))),
              contextUsed: used,
              contextTotal: ctx,
            }),
          );
        }
        break;
      }
      case 'account/rateLimits/updated': {
        const rl = params.rateLimits || {};
        this._emit(
          conn,
          E.usageUpdate({
            fiveHour: rl.primary ? { percent: rl.primary.usedPercent } : undefined,
            weekly: rl.secondary ? { percent: rl.secondary.usedPercent } : undefined,
          }),
        );
        break;
      }
      // Ignore noisy/informational events
      case 'thread/status/changed':
      case 'thread/archived':
      case 'thread/unarchived':
      case 'thread/name/updated':
      case 'thread/compacted':
      case 'thread/realtime/started':
      case 'thread/realtime/itemAdded':
      case 'thread/realtime/transcriptUpdated':
      case 'thread/realtime/outputAudio/delta':
      case 'thread/realtime/error':
      case 'thread/realtime/closed':
      case 'skills/changed':
      case 'hook/started':
      case 'hook/completed':
      case 'item/updated':
      case 'item/autoApprovalReview/started':
      case 'item/autoApprovalReview/completed':
      case 'serverRequest/resolved':
      case 'mcpServer/startupStatus/updated':
      case 'mcpServer/oauthLogin/completed':
      case 'account/updated':
      case 'account/login/completed':
      case 'app/list/updated':
      case 'fs/changed':
      case 'model/rerouted':
      case 'deprecationNotice':
      case 'configWarning':
      case 'fuzzyFileSearch/sessionUpdated':
      case 'fuzzyFileSearch/sessionCompleted':
      case 'windows/worldWritableWarning':
      case 'windowsSandbox/setupCompleted':
        break;

      default:
        console.log(`[codex-provider] Unhandled: ${method}`);
    }
  }
}
