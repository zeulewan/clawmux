/**
 * pi (@mariozechner/pi-coding-agent) provider.
 *
 * Spawns `pi --mode rpc` and speaks the RPC JSONL protocol over stdio.
 * One long-lived process per agent connection. Sessions persist at
 * ~/.pi/agent/sessions/ and can be resumed via --session <path>.
 *
 * Protocol framing: strict \n-delimited JSONL. We do NOT use Node's
 * readline because it also splits on U+2028/U+2029, which are valid
 * inside JSON strings. See docs/rpc.md in the pi package.
 */

import { spawn, execSync } from 'child_process';
import { writeFileSync, appendFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { E } from './events.js';
import { hashProjectPath } from '../sessions.js';

const PI_CMD = process.env.PI_CMD || 'pi';

/**
 * Discover available models by running `pi --list-models`.
 * Returns an array of { id, label, contextWindow } entries.
 */
export function discoverPiModels() {
  try {
    const output = execSync(`${PI_CMD} --list-models 2>&1`, { encoding: 'utf8', timeout: 10000 });
    const lines = output.trim().split('\n').slice(1); // skip header
    const models = [];
    for (const line of lines) {
      const parts = line.trim().split(/\s+/);
      if (parts.length < 3) continue;
      const [provider, model, ctx] = parts;
      const ctxNum = parseInt(ctx) * 1000 || 200000;
      models.push({
        id: `${provider}/${model}`,
        label: model,
        contextWindow: ctxNum,
      });
    }
    return models;
  } catch {
    return null;
  }
}

export class PiProvider {
  constructor() {
    this.name = 'pi';
  }

  /**
   * Spawn a pi RPC process.
   * @param {object} config - { cwd, model, provider, resume }
   *   - resume: session file path or partial UUID; omit for new session
   * @returns {object} connection
   */
  connect(config = {}) {
    const args = ['--mode', 'rpc'];
    if (config.provider) args.push('--provider', config.provider);
    if (config.model && config.model !== 'default') args.push('--model', config.model);
    if (config.resume) args.push('--session', config.resume);

    const proc = spawn(PI_CMD, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, CMX_AGENT: config.agentId || '' },
      cwd: config.cwd || process.cwd(),
    });

    const conn = {
      proc,
      cwd: config.cwd || process.cwd(),
      sessionId: null,
      sessionFile: null,
      listeners: new Set(),
      alive: true,
      _stdoutBuf: '',
      _pendingRequests: new Map(), // id → resolve
      _currentText: '',
      _currentThinking: '',
      _currentToolId: null,
      _currentToolArgs: '',
    };

    proc.stdout.on('data', (chunk) => this._onStdout(conn, chunk));

    proc.stderr.on('data', (d) => {
      const t = d.toString().trim();
      if (t) console.error(`[pi-provider] stderr: ${t}`);
      if (t.includes('No session found')) {
        conn._resumeFailed = true;
        this._emit(conn, { type: 'resume_failed' });
      }
    });

    proc.on('exit', (code, signal) => {
      conn.alive = false;
      const isClean = signal === 'SIGTERM' || signal === 'SIGINT' || code === 143 || code === 130;
      if (code !== 0 && !isClean) {
        this._emit(conn, E.turnError(`pi exited with code ${code}`));
      }
      this._emit(conn, E.sessionClosed(isClean ? 'normal' : `exit ${code}`));
    });

    proc.on('error', (err) => {
      conn.alive = false;
      this._emit(conn, E.turnError(`Failed to spawn pi: ${err.message}`));
      this._emit(conn, E.sessionClosed(err.message));
    });

    // Ask for initial state so contextWindow/sessionId are set before first message
    this._getState(conn);
    if (config.effortLevel && config.effortLevel !== 'default') {
      this.setThinkingLevel(conn, config.effortLevel);
    }

    return conn;
  }

  /**
   * Send a user message.
   */
  send(conn, message) {
    this._appendToSession(conn, 'user', message);
    this._write(conn, { type: 'prompt', message });
  }

  /**
   * Abort current turn.
   */
  interrupt(conn) {
    this._write(conn, { type: 'abort' });
  }

  /**
   * Set thinking/reasoning level.
   * Pi levels: off, minimal, low, medium, high, xhigh
   */
  setThinkingLevel(conn, level) {
    // Map ClawMux effort names to pi thinking levels
    const mapped = { low: 'low', medium: 'medium', high: 'high', max: 'xhigh' }[level] || level;
    this._write(conn, { type: 'set_thinking_level', level: mapped });
  }

  /**
   * Subscribe to events from this connection.
   */
  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  /**
   * pi auto-runs tools; there is no permission request flow to respond to.
   * Provide a stub so the session layer's uniform interface holds.
   */
  respondPermission(_conn, _requestId, _allowed) {
    // no-op
  }

  /**
   * Close the connection.
   */
  close(conn) {
    if (!conn.alive) return;
    try {
      conn.proc.stdin.end();
    } catch {}
    try {
      conn.proc.kill('SIGTERM');
    } catch {}
  }

  // ── internals ──────────────────────────────────────────────────────────

  _write(conn, obj) {
    if (!conn.alive || !conn.proc.stdin.writable) return;
    try {
      conn.proc.stdin.write(JSON.stringify(obj) + '\n');
    } catch (err) {
      console.error(`[pi-provider] write failed: ${err.message}`);
    }
  }

  _getState(conn) {
    const id = `state-${Date.now()}`;
    this._write(conn, { id, type: 'get_state' });
  }

  /**
   * Strict \n-delimited JSONL parsing. Do NOT use readline.
   */
  _onStdout(conn, chunk) {
    conn._stdoutBuf += chunk.toString('utf8');
    let nl;
    while ((nl = conn._stdoutBuf.indexOf('\n')) !== -1) {
      let line = conn._stdoutBuf.slice(0, nl);
      conn._stdoutBuf = conn._stdoutBuf.slice(nl + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        console.error(`[pi-provider] bad JSONL: ${err.message}`);
        continue;
      }
      this._dispatch(conn, msg);
    }
  }

  _dispatch(conn, msg) {
    if (msg.type === 'response') {
      this._handleResponse(conn, msg);
      return;
    }
    this._handleEvent(conn, msg);
  }

  _handleResponse(conn, msg) {
    // Response to get_state: capture session info
    if (msg.command === 'get_state' && msg.success && msg.data) {
      if (msg.data.sessionId && !conn.sessionId) {
        conn.sessionId = msg.data.sessionId;
        this._writeSessionMeta(conn);
        this._flushSessionWrites(conn);
        this._emit(conn, E.sessionReady(msg.data.sessionId));
      }
      if (msg.data.sessionFile) conn.sessionFile = msg.data.sessionFile;
      if (msg.data.model) {
        conn.modelName = msg.data.model.name || msg.data.model.id;
        conn.modelProvider = msg.data.model.provider;
        conn.contextWindow = msg.data.model.contextWindow || 272000;
      }
    }
  }

  _handleEvent(conn, ev) {
    switch (ev.type) {
      case 'agent_start':
        conn._currentText = '';
        conn._currentThinking = '';
        this._emit(conn, E.turnStart());
        break;

      case 'agent_end':
        this._emit(conn, E.turnComplete({}));
        // Re-query state in case session file just materialized
        if (!conn.sessionId) this._getState(conn);
        break;

      case 'turn_end': {
        const usage = ev.message?.usage;
        if (usage?.totalTokens != null && conn.contextWindow) {
          this._emit(
            conn,
            E.usageUpdate({
              contextPercent: Math.max(0, Math.min(100, Math.round((usage.totalTokens / conn.contextWindow) * 100))),
              contextUsed: usage.totalTokens,
              contextTotal: conn.contextWindow,
            }),
          );
        }
        break;
      }

      case 'message_update':
        this._handleMessageDelta(conn, ev.assistantMessageEvent);
        break;

      case 'tool_execution_start':
        this._emit(conn, E.toolStart(ev.toolCallId, ev.toolName, ev.args || {}));
        break;

      case 'tool_execution_update':
        // Bash streaming output — surface as command output if available
        if (ev.toolName === 'bash' && ev.partialResult?.content?.[0]?.text) {
          this._emit(conn, E.commandOutput(ev.toolCallId, ev.partialResult.content[0].text));
        }
        break;

      case 'tool_execution_end': {
        const content = ev.result?.content || [];
        const text = content.map((c) => c.text || '').join('');
        this._emit(conn, E.toolResult(ev.toolCallId, text, Boolean(ev.isError)));
        break;
      }

      case 'extension_error':
        this._emit(conn, E.turnError(`pi extension error: ${ev.message || 'unknown'}`));
        break;

      // turn_start, turn_end, message_start, message_end, queue_update,
      // compaction_*, auto_retry_* — ignore (we track via agent_start/end and deltas)
      default:
        break;
    }
  }

  _handleMessageDelta(conn, delta) {
    if (!delta) return;
    switch (delta.type) {
      case 'text_delta':
        if (delta.delta) {
          conn._currentText += delta.delta;
          this._emit(conn, E.textDelta(delta.delta));
        }
        break;

      case 'text_end':
        if (delta.content) {
          this._emit(conn, E.textDone(delta.content));
          // Assistant session writes handled by provider-session at turn_complete
        }
        conn._currentText = '';
        break;

      case 'thinking_delta':
        if (delta.delta) {
          conn._currentThinking += delta.delta;
          this._emit(conn, E.thinkingDelta(delta.delta));
        }
        break;

      case 'thinking_end':
        if (delta.content) this._emit(conn, E.thinkingDone(delta.content));
        conn._currentThinking = '';
        break;

      case 'toolcall_start':
        conn._currentToolId = delta.toolCall?.id || delta.id || null;
        conn._currentToolArgs = '';
        if (conn._currentToolId) {
          this._emit(conn, E.toolStart(conn._currentToolId, delta.toolCall?.name || delta.name || 'tool', {}));
        }
        break;

      case 'toolcall_delta':
        if (delta.delta && conn._currentToolId) {
          conn._currentToolArgs += delta.delta;
          this._emit(conn, E.toolInputDelta(conn._currentToolId, delta.delta));
        }
        break;

      case 'toolcall_end':
        conn._currentToolId = null;
        conn._currentToolArgs = '';
        break;

      case 'error':
        this._emit(conn, E.turnError(`pi: ${delta.reason || 'error'}`));
        break;

      // start, done — turn lifecycle handled via agent_start/agent_end
      default:
        break;
    }
  }

  _getSessionPath(conn) {
    const CLAUDE_PROJECTS_DIR = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');
    const hashed = hashProjectPath(conn.cwd);
    const dir = join(CLAUDE_PROJECTS_DIR, hashed);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const id = conn.sessionId || conn.sessionFile || 'pi-' + Date.now();
    return join(dir, `${id}.jsonl`);
  }

  _writeSessionMeta(conn) {
    try {
      const path = this._getSessionPath(conn);
      const entry = JSON.stringify({
        type: 'session_meta',
        provider: 'pi',
        sessionId: conn.sessionId,
        timestamp: new Date().toISOString(),
      });
      writeFileSync(path, entry + '\n');
    } catch {}
  }

  _appendToSession(conn, role, text) {
    const entry = JSON.stringify({
      type: role,
      message: { role, content: [{ type: 'text', text }] },
      timestamp: new Date().toISOString(),
    });
    // Queue writes until sessionId is known
    if (!conn.sessionId) {
      if (!conn._pendingSessionWrites) conn._pendingSessionWrites = [];
      conn._pendingSessionWrites.push(entry);
      return;
    }
    try {
      const path = this._getSessionPath(conn);
      appendFileSync(path, entry + '\n');
    } catch {}
  }

  _flushSessionWrites(conn) {
    if (!conn._pendingSessionWrites?.length || !conn.sessionId) return;
    try {
      const path = this._getSessionPath(conn);
      for (const entry of conn._pendingSessionWrites) {
        appendFileSync(path, entry + '\n');
      }
    } catch {}
    conn._pendingSessionWrites = [];
  }

  _emit(conn, event) {
    for (const listener of conn.listeners) {
      try {
        listener(event);
      } catch (err) {
        console.error(`[pi-provider] listener error: ${err.message}`);
      }
    }
  }
}
