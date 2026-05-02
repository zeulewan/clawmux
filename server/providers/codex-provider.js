/**
 * Codex App Server provider.
 *
 * Spawns `codex app-server` per session and talks JSON-RPC over stdio.
 * Translates JSON-RPC notifications into internal events.
 *
 * Tool execution: App-server handles it internally.
 * Permission flow: Server sends requestApproval, we auto-approve.
 */

import { writeFileSync, appendFileSync, mkdirSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { CodexAppServerClient } from './codex-app-server-client.js';
import { CodexSessionRuntime } from './codex-session-runtime.js';
import { E } from './events.js';
import { hashProjectPath } from '../sessions.js';

const CODEX_CMD = process.env.CODEX_CMD || 'codex';
const CODEX_APPROVAL_POLICY = 'never';
const CODEX_SANDBOX_MODE = 'danger-full-access';
const CODEX_SANDBOX_POLICY = { type: 'dangerFullAccess' };

function codexAppServerArgs() {
  return ['app-server', '-c', 'approval_policy="never"', '-c', 'sandbox_mode="danger-full-access"'];
}

/**
 * Discover available models by querying a short-lived codex app-server.
 */
export async function discoverCodexModels() {
  const client = new CodexAppServerClient({
    command: CODEX_CMD,
    args: codexAppServerArgs(),
    requestTimeoutMs: 10000,
    onError: () => {},
  });

  try {
    client.start();
    await client.request('initialize', {
      clientInfo: { name: 'ClawMux-discover', version: '1.0.0' },
      capabilities: { experimentalApi: true },
    });
    client.notify('initialized');
    const result = await client.request('model/list', {});
    const raw = result?.data || result?.models || [];
    return raw
      .filter((m) => !m.hidden)
      .map((m) => ({
        id: m.id || m.model,
        label: m.displayName || m.id || m.model,
        contextWindow: m.contextWindow || m.modelContextWindow || 272000,
      }));
  } catch {
    return null;
  } finally {
    client.close();
  }
}

export class CodexProvider {
  constructor() {
    this.name = 'codex';
    this._connections = new Set();
  }

  /**
   * Connect: start a per-session app-server runtime over stdio.
   * @param {object} config - { cwd, model, resume }
   * @returns {Promise<object>} connection
   */
  async connect(config = {}) {
    const runtime = new CodexSessionRuntime(this, config, { command: CODEX_CMD });
    const conn = await runtime.start();
    this._connections.add(conn);
    return conn;
  }

  /**
   * Send a user message — starts a new turn.
   */
  send(conn, message) {
    conn._runtime?.send(message);
  }

  onEvent(conn, callback) {
    conn.listeners.add(callback);
    return () => conn.listeners.delete(callback);
  }

  respondPermission(conn, requestId, allowed) {
    conn._runtime?.respondPermission(requestId, allowed);
  }

  interrupt(conn) {
    conn._runtime?.interrupt();
  }

  close(conn) {
    conn.alive = false;
    conn._runtime?.close();
    this._connections.delete(conn);
    try {
      conn.ws?.close();
    } catch {}
  }

  /**
   * Shut down all session runtimes.
   */
  shutdown() {
    for (const conn of [...this._connections]) this.close(conn);
  }

  // ── Internal ──

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

  _emitRaw(conn, event) {
    this._emit(conn, E.rawEvent(event));
  }

  _extractThreadId(payload) {
    if (!payload || typeof payload !== 'object') return null;
    return (
      payload.threadId ||
      payload.thread?.id ||
      payload.turn?.threadId ||
      payload.turn?.thread?.id ||
      payload.item?.threadId ||
      payload.item?.thread?.id ||
      null
    );
  }

  _isForeignThreadEvent(conn, payload) {
    const eventThreadId = this._extractThreadId(payload);
    return !!(eventThreadId && conn.threadId && eventThreadId !== conn.threadId);
  }

  _sendWs(conn, payload) {
    if (conn.client) {
      conn.client.send(payload);
      return;
    }

    this._emitRaw(conn, {
      direction: 'out',
      transport: 'ws',
      raw: JSON.stringify(payload),
      payload,
    });
    conn.ws.send(JSON.stringify(payload));
  }

  _serverArgs() {
    return codexAppServerArgs();
  }

  _threadStartParams(conn) {
    const params = {
      cwd: conn.cwd || undefined,
      approvalPolicy: CODEX_APPROVAL_POLICY,
      sandbox: CODEX_SANDBOX_MODE,
    };
    if (conn.model && conn.model !== 'default') params.model = conn.model;
    return params;
  }

  _threadResumeParams(conn, threadId) {
    const params = {
      threadId,
      cwd: conn.cwd || undefined,
      approvalPolicy: CODEX_APPROVAL_POLICY,
      sandbox: CODEX_SANDBOX_MODE,
      excludeTurns: true,
    };
    if (conn.model && conn.model !== 'default') params.model = conn.model;
    return params;
  }

  _turnStartParams(conn, message) {
    const params = {
      threadId: conn.threadId,
      input: [{ type: 'text', text: message }],
      effort: conn.effortLevel || undefined,
      approvalPolicy: CODEX_APPROVAL_POLICY,
      sandboxPolicy: CODEX_SANDBOX_POLICY,
    };
    if (conn.model && conn.model !== 'default') params.model = conn.model;
    return params;
  }

  _userInputResponse(params = {}) {
    const questions = Array.isArray(params.questions) ? params.questions : [];
    const answers = {};
    for (const question of questions) {
      if (!question?.id) continue;
      const firstOption = Array.isArray(question.options) ? question.options[0] : null;
      const answer = firstOption?.label || (question.isSecret ? '' : 'ok');
      answers[question.id] = { answers: [answer] };
    }
    return { answers };
  }

  _handleMessage(conn, msg) {
    // JSON-RPC notification or server request (has method)
    if (msg.method) {
      const isRequest = msg.id !== undefined && msg.id !== null;
      console.debug(`[codex-provider] ← ${msg.method}${isRequest ? ' (request)' : ''}`);
      this._handleNotification(conn, msg.method, msg.params || {}, msg.id);
      return;
    }

    // JSON-RPC response (has id)
    if (msg.id !== undefined && msg.id !== null && msg.result) {
      // turn/start response — emit turnStart here as Codex doesn't always send turn/started notification
      if (msg.result.turn) {
        if (msg.result.turn.threadId && (!conn.threadId || conn.threadId === msg.result.turn.threadId)) {
          conn.threadId = msg.result.turn.threadId;
        }
        conn.turnId = msg.result.turn.id;
        // Guard: emit once per turn (turn/started notification may also arrive)
        if (conn._turnStartEmitted !== conn.turnId) {
          conn._turnStartEmitted = conn.turnId;
          this._emit(conn, E.turnStart());
        }
      }
    }

    // JSON-RPC error
    if (msg.id !== undefined && msg.id !== null && msg.error) {
      this._emit(conn, E.turnError(msg.error.message || 'Codex error'));
    }
  }

  _handleNotification(conn, method, params, msgId) {
    if (this._isForeignThreadEvent(conn, params)) return;

    switch (method) {
      case 'thread/started':
        if (!conn.threadId && params.thread?.id) conn.threadId = params.thread.id;
        break;

      case 'turn/started':
        if (params.turn?.threadId && !conn.threadId) conn.threadId = params.turn.threadId;
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
        if (msgId !== undefined && msgId !== null) {
          console.warn(`[codex-provider] Terminal interaction requested — auto-sending empty response`);
          this._sendWs(conn, { id: msgId, result: { input: '' } });
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
        const reqId = msgId ?? params.requestId ?? params.id;
        if (reqId === undefined || reqId === null) {
          console.warn(
            `[codex-provider] ${method} arrived without request id; params keys=${Object.keys(params).join(',') || '(none)'}`,
          );
          break;
        }
        console.log(`[codex-provider] Auto-approving ${method} (id=${reqId})`);
        if (method === 'item/permissions/requestApproval') {
          this._sendWs(conn, {
            id: reqId,
            result: {
              permissions: params.permissions || {},
              scope: 'session',
            },
          });
        } else {
          this.respondPermission(conn, reqId, true);
        }
        break;
      }

      case 'item/tool/requestUserInput': {
        const reqId = msgId ?? params.requestId ?? params.id;
        if (reqId === undefined || reqId === null) {
          console.warn(
            `[codex-provider] ${method} arrived without request id; params keys=${Object.keys(params).join(',') || '(none)'}`,
          );
          break;
        }
        console.warn(`[codex-provider] Auto-answering ${method} (id=${reqId})`);
        this._sendWs(conn, { id: reqId, result: this._userInputResponse(params) });
        break;
      }

      case 'mcpServer/elicitation/request': {
        const reqId = msgId ?? params.requestId ?? params.id;
        if (reqId === undefined || reqId === null) {
          console.warn(
            `[codex-provider] ${method} arrived without request id; params keys=${Object.keys(params).join(',') || '(none)'}`,
          );
          break;
        }
        console.warn(`[codex-provider] Cancelling unsupported ${method} (id=${reqId})`);
        this._sendWs(conn, { id: reqId, result: { action: 'cancel' } });
        break;
      }

      case 'turn/completed': {
        conn.turnId = null;
        conn._turnStartEmitted = null;
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
        conn.turnId = null;
        conn._turnStartEmitted = null;
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
      case 'remoteControl/status/changed':
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
