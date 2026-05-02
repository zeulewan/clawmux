import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { E } from './events.js';
import { hashProjectPath } from '../sessions.js';

const CLAUDE_CMD = process.env.CLAUDE_CMD || 'claude';
const CLAUDE_CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude');
const RECOVERABLE_RESUME_ERROR_SNIPPETS = ['no conversation found', 'session not found', 'resume failed'];

function hasPersistedClaudeSession(sessionId, cwd) {
  if (!sessionId) return false;
  const hashed = hashProjectPath(cwd || process.cwd());
  return existsSync(join(CLAUDE_CONFIG_DIR, 'projects', hashed, `${sessionId}.jsonl`));
}

export function isRecoverableClaudeResumeError(error) {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  return message.includes('resume') && RECOVERABLE_RESUME_ERROR_SNIPPETS.some((snippet) => message.includes(snippet));
}

export class ClaudeSessionRuntime {
  constructor(provider, config = {}, options = {}) {
    this.provider = provider;
    this.config = { ...config };
    this.queryImpl = options.queryImpl || query;
    this.sessionExists = options.sessionExists || hasPersistedClaudeSession;
    this.conn = {
      sessionId: config.resume || null,
      listeners: new Set(),
      alive: false,
      cwd: config.cwd,
      model: config.model,
      effortLevel: config.effortLevel || null,
      permissionMode: config.permissionMode || 'bypassPermissions',
      _pendingApprovals: new Map(),
      _currentToolId: null,
      _textBlockOpen: false,
      _thinkingBlockOpen: false,
      _runtime: this,
    };
    this._closed = false;
    this._promptQueue = [];
    this._promptWaiter = null;
    this._resumeFailed = false;
    this._query = null;
  }

  async start() {
    const conn = this.conn;
    conn.alive = true;

    if (this.config.resume && !this.sessionExists(this.config.resume, conn.cwd || process.cwd())) {
      queueMicrotask(() => {
        if (!conn.alive) return;
        this.provider._emit(conn, { type: 'resume_failed' });
      });
      return conn;
    }

    try {
      this._query = this.queryImpl({
        prompt: this._promptStream(),
        options: this._queryOptions(),
      });
    } catch (err) {
      conn.alive = false;
      throw new Error(`Failed to start Claude SDK: ${err.message || err}`);
    }

    conn.query = this._query;
    this._pumpMessages();
    return conn;
  }

  send(message) {
    const conn = this.conn;
    if (!conn.alive) return;
    const payload = {
      type: 'user',
      uuid: randomUUID(),
      session_id: conn.sessionId || '',
      parent_tool_use_id: null,
      message: { role: 'user', content: [{ type: 'text', text: message }] },
    };
    this.provider._emitRaw(conn, {
      direction: 'out',
      transport: 'sdk',
      payload,
      summary: 'user',
    });
    this._pushPrompt(payload);
  }

  respondPermission(requestId, allowed) {
    const pending = this.conn._pendingApprovals.get(requestId);
    if (!pending) return;
    this.provider._emitRaw(this.conn, {
      direction: 'out',
      transport: 'sdk',
      payload: {
        type: 'control_response',
        response: {
          request_id: requestId,
          subtype: 'success',
          result: { behavior: allowed ? 'allow' : 'deny' },
        },
      },
      summary: 'control_response',
    });
    pending(
      allowed
        ? { behavior: 'allow', toolUseID: requestId }
        : { behavior: 'deny', message: 'Denied by user', toolUseID: requestId },
    );
  }

  interrupt() {
    if (!this.conn.alive) return;
    this.provider._emitRaw(this.conn, {
      direction: 'out',
      transport: 'sdk',
      payload: {
        type: 'control_request',
        request: { subtype: 'interrupt' },
      },
      summary: 'interrupt',
    });
    this._query?.interrupt?.().catch((err) => {
      if (this.conn.alive) this.provider._emit(this.conn, E.turnError(err.message || 'Claude interrupt failed'));
    });
  }

  close() {
    if (this._closed) return;
    this._closed = true;
    this.conn.alive = false;
    for (const resolve of this.conn._pendingApprovals.values()) {
      resolve({ behavior: 'deny', message: 'Session closed' });
    }
    this.conn._pendingApprovals.clear();
    this._resolvePromptWaiter(null);
    try {
      this._query?.close?.();
    } catch {}
  }

  setThinkingLevel(level) {
    const normalized = level === 'xhigh' ? 'max' : level;
    this.conn.effortLevel = normalized;
    if (!this.conn.alive || !normalized) return Promise.resolve();
    return this._query?.applyFlagSettings?.({ effortLevel: normalized }).catch((err) => {
      if (this.conn.alive) this.provider._emit(this.conn, E.turnError(err.message || 'Claude effort update failed'));
    });
  }

  setPermissionMode(mode) {
    this.conn.permissionMode = mode;
    if (!this.conn.alive) return Promise.resolve();
    return this._query?.setPermissionMode?.(mode).catch((err) => {
      if (this.conn.alive)
        this.provider._emit(this.conn, E.turnError(err.message || 'Claude permission mode update failed'));
    });
  }

  _queryOptions() {
    const permissionMode = this.conn.permissionMode || 'bypassPermissions';
    return {
      cwd: this.conn.cwd || process.cwd(),
      model: this.conn.model && this.conn.model !== 'default' ? this.conn.model : undefined,
      resume: this.config.resume || undefined,
      effort: this.conn.effortLevel && this.conn.effortLevel !== 'default' ? this.conn.effortLevel : undefined,
      includePartialMessages: true,
      permissionMode,
      allowDangerouslySkipPermissions: permissionMode === 'bypassPermissions',
      pathToClaudeCodeExecutable: CLAUDE_CMD,
      env: {
        ...process.env,
        CMX_AGENT: this.config.agentId || '',
        CLAUDE_AGENT_SDK_CLIENT_APP: 'clawmux/1.0.0',
      },
      stderr: (data) => this._handleStderr(data),
      canUseTool: (toolName, input, options) => this._canUseTool(toolName, input, options),
      onElicitation: async (request) => {
        this.provider._emitRaw(this.conn, {
          direction: 'in',
          transport: 'sdk',
          payload: {
            type: 'control_request',
            request: {
              subtype: 'elicitation',
              mcp_server_name: request.serverName,
              message: request.message,
              mode: request.mode,
            },
          },
          summary: 'elicitation',
        });
        return { action: 'cancel' };
      },
    };
  }

  async _pumpMessages() {
    const conn = this.conn;
    try {
      for await (const parsed of this._query) {
        this.provider._emitRaw(conn, {
          direction: 'in',
          transport: 'sdk',
          payload: parsed,
        });
        this.provider._handleEvent(conn, parsed);
      }

      if (!conn.alive) return;
      conn.alive = false;
      if (this._resumeFailed && this.config.resume) {
        this.provider._emit(conn, { type: 'resume_failed' });
        return;
      }
      this.provider._emit(conn, E.sessionClosed('normal'));
    } catch (err) {
      if (!conn.alive) return;
      conn.alive = false;
      if ((this._resumeFailed || isRecoverableClaudeResumeError(err)) && this.config.resume) {
        this.provider._emit(conn, { type: 'resume_failed' });
        return;
      }
      this.provider._emit(conn, E.turnError(`Claude SDK failed: ${err.message || err}`));
      this.provider._emit(conn, E.sessionClosed(err.message || String(err)));
    } finally {
      this._closed = true;
      this._resolvePromptWaiter(null);
      for (const resolve of conn._pendingApprovals.values()) {
        resolve({ behavior: 'deny', message: 'Session closed' });
      }
      conn._pendingApprovals.clear();
    }
  }

  async _canUseTool(toolName, input, options = {}) {
    const requestId = options.toolUseID || randomUUID();
    this.provider._emitRaw(this.conn, {
      direction: 'in',
      transport: 'sdk',
      payload: {
        type: 'control_request',
        request_id: requestId,
        request: {
          subtype: 'can_use_tool',
          tool_name: toolName,
          input,
          tool_use_id: requestId,
          title: options.title,
          display_name: options.displayName,
          description: options.description,
        },
      },
      summary: 'can_use_tool',
    });

    return await new Promise((resolve) => {
      const cleanup = () => {
        this.conn._pendingApprovals.delete(requestId);
        options.signal?.removeEventListener?.('abort', onAbort);
      };

      const onAbort = () => {
        cleanup();
        resolve({ behavior: 'deny', message: 'Permission request aborted', interrupt: true, toolUseID: requestId });
      };

      this.conn._pendingApprovals.set(requestId, (result) => {
        cleanup();
        resolve(result);
      });

      options.signal?.addEventListener?.('abort', onAbort, { once: true });
      this.provider._emit(this.conn, E.permissionRequest(requestId, toolName, input));
    });
  }

  async *_promptStream() {
    while (!this._closed) {
      if (this._promptQueue.length > 0) {
        yield this._promptQueue.shift();
        continue;
      }
      const next = await new Promise((resolve) => {
        this._promptWaiter = resolve;
      });
      if (next == null) return;
      yield next;
    }
  }

  _pushPrompt(payload) {
    if (this._promptWaiter) {
      this._resolvePromptWaiter(payload);
      return;
    }
    this._promptQueue.push(payload);
  }

  _resolvePromptWaiter(payload) {
    const waiter = this._promptWaiter;
    this._promptWaiter = null;
    waiter?.(payload);
  }

  _handleStderr(data) {
    const text = String(data || '').trim();
    if (!text) return;
    this.provider._emitRaw(this.conn, {
      direction: 'err',
      transport: 'stderr',
      raw: text,
      payload: { type: 'stderr', text },
    });
    console.error(`[claude-provider] stderr: ${text}`);
    if (text.toLowerCase().includes('no conversation found') || text.toLowerCase().includes('session not found')) {
      this._resumeFailed = true;
    }
  }
}
