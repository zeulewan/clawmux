/**
 * ProviderSession — manages one WebSocket client with any provider backend.
 *
 * Wraps the provider interface and translates between:
 * - Frontend protocol (VS Code webview messages)
 * - Provider internal events
 *
 * Replaces ClaudeCodeSession for multi-backend support, but
 * maintains full backward compatibility with the existing frontend.
 */

import crypto from 'crypto';
import { join } from 'path';
import { homedir } from 'os';
import { writeFileSync, appendFileSync, existsSync, mkdirSync, unlinkSync } from 'fs';
import { EventEmitter } from 'events';
import { getProvider } from './providers/provider.js';

// Global event bus for monitor state changes
export const monitorBus = new EventEmitter();
monitorBus.setMaxListeners(50);
import { getLastUsage as getPolledUsage } from './usage-poller.js';
import { listClaudeCliSessions, readSessionMessages, hashProjectPath } from './sessions.js';
import {
  getBackendsConfig,
  getDefaultBackend,
  getAgentBackend,
  setAgentSession,
  getAgentModel,
  getAgentEffort,
  setAgentModel,
  setAgentEffort,
} from './config.js';

const CLAUDE_PROJECTS_DIR = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'projects');

const RETIRED_PROVIDERS = { openclaw: true, glueclaw: true };
function _remapRetiredProvider(name) {
  return RETIRED_PROVIDERS[name] ? getDefaultBackend() : name;
}

export default class ProviderSession {
  constructor(sendFn, cwd, agentId, agentProcs) {
    this._sendFn = sendFn;
    this.cwd = cwd;
    this.agentId = agentId;
    this.agentProcs = agentProcs;
    this.lastUsage = null;

    // Provider reads backend from config at launch time
    this.providerName = getAgentBackend(agentId);
    this.provider = null;
    this.connections = new Map(); // channelId → { conn, unsub }
    this._pendingMessages = new Map(); // channelId → [messages] (queued while connecting)

    // Live state for monitor
    this.state = {
      status: 'offline',
      currentTool: null,
      lastActivity: null,
    };
  }

  _updateState(status, currentTool = null) {
    this.state.status = status;
    this.state.currentTool = currentTool;
    this.state.lastActivity = Date.now();
    monitorBus.emit('change', this.agentId);

    // Stale stream watchdog: if agent stays in an active state too long without
    // any events, transition to error. Resets on every state update.
    if (this._staleTimer) clearTimeout(this._staleTimer);
    const activeStates = ['thinking', 'responding', 'tool_call'];
    if (activeStates.includes(status)) {
      this._staleTimer = setTimeout(() => {
        if (activeStates.includes(this.state.status)) {
          const staleSec = Math.round((Date.now() - this.state.lastActivity) / 1000);
          console.log(`[watchdog] ${this.agentId} stale for ${staleSec}s in ${this.state.status} — transitioning to error`);
          this.state.status = 'error';
          this.state.currentTool = null;
          this.state.lastActivity = Date.now();
          monitorBus.emit('change', this.agentId);
        }
      }, 120000); // 2 minutes without any event = stale
    }
  }

  setSendFn(fn) {
    if (!fn) return; // ignore null — use removeSendFn to clean up
    // Support multiple browser connections — add to set, don't replace
    if (!this._sendFns) this._sendFns = new Set();
    this._sendFns.add(fn);
    this._sendFn = fn;
  }

  removeSendFn(fn) {
    if (this._sendFns) this._sendFns.delete(fn);
  }

  send(msg) {
    const payload = { ...msg, agentId: this.agentId };
    if (this._sendFns?.size > 0) {
      for (const fn of this._sendFns) {
        try { fn(payload); } catch {}
      }
    } else if (this._sendFn) {
      this._sendFn(payload);
    }
  }

  handleMessage(msg) {
    switch (msg.type) {
      case 'request':
        this.handleRequest(msg);
        break;
      case 'launch':
        this.launchProvider(msg);
        break;
      case 'io_message':
        this.handleIoMessage(msg);
        break;
      case 'interrupt':
        this.interruptProvider(msg.channelId);
        break;
      case 'close_channel':
        this.closeChannel(msg.channelId);
        break;
      case 'set_provider':
        this.setProvider(msg.provider);
        break;
      case 'response': {
        // Permission response from frontend
        const entry = msg.channelId ? this.connections.get(msg.channelId) : undefined;
        if (entry?.conn && this.provider) {
          const allowed = msg.response?.result?.behavior === 'allow';
          this.provider.respondPermission(entry.conn, msg.requestId, allowed);
        }
        break;
      }
      case 'cancel_request':
        break;
      case 'start_speech_to_text':
      case 'stop_speech_to_text':
        break;
    }
  }

  setProvider(name) {
    if (name && name !== this.providerName) {
      // Close existing connections
      for (const [channelId, entry] of this.connections) {
        if (entry.unsub) entry.unsub();
        if (this.provider) this.provider.close(entry.conn);
      }
      this.connections.clear();
      this.providerName = name;
      this.provider = null;
      console.log(`[session] Provider switched to: ${name}`);
    }
  }

  /** Kill all active connections (called when backend/model changes via API). */
  killConnections() {
    for (const [oldId, entry] of this.connections) {
      if (entry.unsub) entry.unsub();
      if (this.provider) this.provider.close(entry.conn);
    }
    this.connections.clear();
    this.provider = null;
  }

  async launchProvider(msg) {
    const { channelId, resume, cwd } = msg;

    if (this._launching) {
      // Safety: if _launching has been stuck for over 30s, force-clear it
      const launchAge = this._launchStarted ? Date.now() - this._launchStarted : 0;
      if (launchAge < 30000) {
        console.log(`[launch] Skipping concurrent launch for ${this.agentId} (already launching, ${Math.round(launchAge / 1000)}s ago)`);
        return;
      }
      console.warn(`[launch] Force-clearing stale _launching for ${this.agentId} (stuck ${Math.round(launchAge / 1000)}s)`);
    }
    this._launching = true;
    this._launchStarted = Date.now();

    // Read backend/model/effort from server config (single source of truth)
    const configBackend = getAgentBackend(this.agentId);
    const configModel = getAgentModel(this.agentId);
    const configEffort = getAgentEffort(this.agentId);

    // Warn if launch message specifies a different provider than what's configured
    if (msg.provider && msg.provider !== configBackend) {
      console.warn(`[launch] ${this.agentId}: launch requested provider="${msg.provider}" but config says "${configBackend}" — using config`);
    }

    // Switch provider if config changed
    if (configBackend !== this.providerName) {
      this.setProvider(configBackend);
    }

    // If we already have a live connection and backend hasn't changed,
    // reuse it (just remap the channelId) instead of killing + respawning
    if (this.connections.size > 0 && this.provider) {
      const [[oldChannelId, entry]] = this.connections;
      if (entry.conn?.alive !== false) {
        const wasStreaming = ['thinking', 'responding', 'tool_call'].includes(this.state.status);
        // Remap: new channelId → existing connection
        this.connections.delete(oldChannelId);
        this.connections.set(channelId, entry);
        if (this._turnState?.[oldChannelId]) {
          delete this._turnState[oldChannelId];
        }
        this._updateState(wasStreaming ? this.state.status : 'idle', wasStreaming ? this.state.currentTool : null);
        console.log(`[launch] Reusing live connection for ${this.agentId} (${oldChannelId} → ${channelId})`);

        // Re-subscribe events to the new channelId
        if (entry.unsub) entry.unsub();
        const unsub = this.provider.onEvent(entry.conn, (event) => {
          this._handleProviderEvent(channelId, event);
        });
        entry.unsub = unsub;

        if (this.agentId) {
          this.agentProcs.set(this.agentId, { conn: entry.conn, channelId, session: this });
        }
        // Emit session_ready so frontend gets the session ID
        const sid = entry.sessionId || entry.conn?.threadId || entry.conn?.sessionId;
        if (sid) {
          this._handleProviderEvent(channelId, { type: 'session_ready', sessionId: sid });
        }
        if (wasStreaming) {
          // A reconnect gets a fresh client-side session object. Re-open the
          // assistant turn so subsequent deltas have somewhere to land.
          this._turnState[channelId] = { blockStarted: false, thinkingBlockStarted: false };
          this.send({
            type: 'io_message',
            channelId,
            message: { type: 'message_start', message: { role: 'assistant' } },
          });
        }
        this._flushPending(channelId);
        this._launching = false;
        return;
      }
    }

    // Reset state for fresh launch
    this._updateState('idle');

    // Kill old connections
    for (const [oldId, entry] of this.connections) {
      if (entry.unsub) entry.unsub();
      if (this.provider && entry.conn) this.provider.close(entry.conn);
    }
    this.connections.clear();

    if (!this.provider) {
      this.provider = getProvider(this.providerName);
    }

    const spawnCwd = cwd || this.cwd;

    console.log(
      `[launch] provider=${this.providerName} agent=${this.agentId} channel=${channelId} resume=${resume || 'new'} model=${configModel} cwd=${spawnCwd}`,
    );

    try {
      const conn = await this.provider.connect({
        cwd: spawnCwd,
        model: configModel,
        resume,
        agentId: this.agentId,
        effortLevel: configEffort,
      });

      // Subscribe to events and translate to frontend protocol
      const unsub = this.provider.onEvent(conn, (event) => {
        this._handleProviderEvent(channelId, event);
      });

      this.connections.set(channelId, { conn, unsub, sessionId: resume });

      // Flush any messages queued while connecting
      this._flushPending(channelId);

      // Register in global agent procs
      if (this.agentId) {
        this.agentProcs.set(this.agentId, { conn, channelId, session: this });
      }

      // For providers that set sessionId/threadId on conn, emit session_ready
      // so the frontend gets the real UUID (not the channel ID)
      const realSessionId = conn.sessionId || conn.threadId;
      if (realSessionId) {
        this._handleProviderEvent(channelId, { type: 'session_ready', sessionId: realSessionId });
      }
    } catch (err) {
      console.error(`[launch] Failed to connect ${this.providerName}:`, err.message);
      // Show error in chat as an assistant message
      this.send({
        type: 'io_message',
        channelId,
        message: { type: 'message_start', message: { role: 'assistant' } },
      });
      this.send({
        type: 'io_message',
        channelId,
        message: {
          type: 'content_block_start',
          content_block: { type: 'text', text: '' },
        },
      });
      this.send({
        type: 'io_message',
        channelId,
        message: {
          type: 'content_block_delta',
          delta: {
            type: 'text_delta',
            text: `**Error:** Failed to connect to ${this.providerName}: ${err.message}`,
          },
        },
      });
      this.send({
        type: 'io_message',
        channelId,
        message: { type: 'result', subtype: 'error', error: err.message },
      });
    } finally {
      this._launching = false;
    }
  }

  handleIoMessage(msg) {
    const entry = this.connections.get(msg.channelId);
    if (!entry?.conn || !this.provider) {
      if (!this._pendingMessages.has(msg.channelId)) {
        this._pendingMessages.set(msg.channelId, []);
      }
      this._pendingMessages.get(msg.channelId).push(msg);
      console.log(`[session] Queued message for ${msg.channelId} (connection not ready)`);
      return;
    }

    // Track last sent message so we can re-send on resume_failed
    this._lastSentMessage = msg;
    this._sendToProvider(entry, msg);
  }

  _flushPending(channelId) {
    const pending = this._pendingMessages.get(channelId);
    if (!pending?.length) return;
    const entry = this.connections.get(channelId);
    if (!entry) return;
    console.log(`[session] Flushing ${pending.length} queued messages for ${channelId}`);
    for (const m of pending) this._sendToProvider(entry, m);
    this._pendingMessages.delete(channelId);
  }

  _sendToProvider(entry, msg) {
    const message = msg.message;
    let text = '';
    if (message?.type === 'user' && message?.message?.role === 'user') {
      text = message.message.content?.map((b) => b.text || '').join('') || '';
    } else if (message?.role === 'user' && message?.content) {
      text = message.content?.map((b) => b.text || '').join('') || '';
    }

    if (text) {
      console.log(`[session] → provider.send: "${text.slice(0, 50)}"`);
      this.provider.send(entry.conn, text);
    }
  }

  interruptProvider(channelId) {
    const entry = this.connections.get(channelId);
    if (entry?.conn && this.provider) {
      console.log(`[session] Interrupting ${this.providerName} channel ${channelId}`);
      this.provider.interrupt(entry.conn);
    } else {
      // Try interrupting any active connection
      for (const [id, e] of this.connections) {
        if (e.conn && this.provider) {
          console.log(`[session] Interrupting ${this.providerName} via fallback channel ${id}`);
          this.provider.interrupt(e.conn);
          break;
        }
      }
    }
  }

  closeChannel(channelId) {
    const entry = this.connections.get(channelId);
    if (entry) {
      if (entry.unsub) entry.unsub();
      if (this.provider) this.provider.close(entry.conn);
      this.connections.delete(channelId);
    }
    // Clean up turn state for this channel
    if (this._turnState) delete this._turnState[channelId];
  }

  handleRequest(msg) {
    const { requestId, request } = msg;
    const respond = (response) => {
      this.send({ type: 'response', requestId, response });
    };

    switch (request.type) {
      case 'list_sessions_request': {
        const sessions = listClaudeCliSessions(this.cwd);
        respond({
          type: 'list_sessions_response',
          sessions: sessions.map((s) => ({
            id: s.sessionId,
            lastModified: s.lastModified,
            fileSize: s.fileSize,
            summary: s.summary,
            isCurrentWorkspace: true,
            provider: _remapRetiredProvider(s.provider) || getDefaultBackend(),
          })),
        });
        break;
      }
      case 'get_session_request': {
        const messages = readSessionMessages(request.sessionId, this.cwd);
        respond({ type: 'get_session_response', messages, sessionDiffs: undefined });
        break;
      }
      case 'delete_session': {
        const delId = request.sessionId;
        if (delId) {
          const hashed = hashProjectPath(this.cwd);
          const sessionPath = join(CLAUDE_PROJECTS_DIR, hashed, `${delId}.jsonl`);
          try {
            if (existsSync(sessionPath)) unlinkSync(sessionPath);
            console.log(`[session] Deleted session file: ${delId}`);
          } catch (err) {
            console.error(`[session] Failed to delete ${delId}: ${err.message}`);
          }
        }
        respond({ type: 'delete_session_response' });
        break;
      }
      case 'rename_session': {
        const { sessionId, title } = request;
        if (sessionId && title) {
          // Write a summary line to the session JSONL file
          const hashed = hashProjectPath(this.cwd);
          const sessionPath = join(CLAUDE_PROJECTS_DIR, hashed, `${sessionId}.jsonl`);
          if (existsSync(sessionPath)) {
            const summaryLine = JSON.stringify({ type: 'summary', summary: title }) + '\n';
            try {
              appendFileSync(sessionPath, summaryLine);
            } catch (err) {
              console.error(`[session] Failed to persist rename for ${sessionId}:`, err.message);
            }
          }
        }
        respond({ type: 'rename_session_response', skipped: false });
        break;
      }
      case 'fork_conversation': {
        const { forkedFromSession, resumeSessionAt } = request;
        const srcMessages = readSessionMessages(forkedFromSession, this.cwd);
        if (srcMessages.length > 0) {
          const newSessionId = crypto.randomUUID();
          const hashed = hashProjectPath(this.cwd);
          const newPath = join(CLAUDE_PROJECTS_DIR, hashed, `${newSessionId}.jsonl`);
          let forked = [];
          for (const m of srcMessages) {
            forked.push(m);
            if (m.uuid === resumeSessionAt) break;
          }
          writeFileSync(newPath, forked.map((m) => JSON.stringify(m)).join('\n') + '\n');
          respond({ type: 'fork_conversation_response', sessionId: newSessionId });
        } else {
          respond({ type: 'fork_conversation_response', sessionId: null });
        }
        break;
      }
      case 'set_model': {
        // Model changes now go through POST /api/agents/:id/model.
        // This RPC path is kept for backward compat — persist to config and kill connections.
        setAgentModel(this.agentId, request.model);
        this.killConnections();
        console.log(`[session] Model changed to: ${request.model}`);
        respond({ type: 'set_model_response', model: request.model });
        break;
      }
      case 'init': {
        const { permissionMode, allowBypass } = this._getPermissionConfigForProvider();
        respond({
          type: 'init_response',
          state: {
            defaultCwd: this.cwd,
            openNewInTab: false,
            showTerminalBanner: false,
            showReviewUpsellBanner: false,
            isOnboardingEnabled: false,
            isOnboardingDismissed: true,
            modelSetting: getAgentModel(this.agentId),
            thinkingLevel: null,
            initialPermissionMode: permissionMode,
            allowDangerouslySkipPermissions: allowBypass,
            platform: 'linux',
            speechToTextEnabled: false,
            marketplaceType: 'none',
            useCtrlEnterToSend: false,
            chromeMcpState: { status: 'disconnected' },
            browserIntegrationSupported: false,
            debuggerMcpState: { status: 'disconnected' },
            jupyterMcpState: { status: 'disconnected' },
            remoteControlState: { status: 'disconnected' },
            spinnerVerbsConfig: null,
            settings: {},
            claudeSettings: { effective: { permissions: {} } },
            currentRepo: null,
            experimentGates: {},
            authStatus: {
              authenticated: true,
              hasActiveSubscription: true,
              accountType: 'max_5x',
              planType: 'max_5x',
            },
            // Tell frontend which provider is active
            provider: this.providerName,
          },
        });
        // Send polled usage data immediately on connect
        const polled = getPolledUsage();
        if (polled) {
          this.lastUsage = { ...this.lastUsage, ...polled };
          this.send({
            type: 'request',
            channelId: '',
            requestId: crypto.randomUUID(),
            request: { type: 'usage_update', utilization: this.lastUsage },
          });
        }
        break;
      }
      case 'get_agent_state':
        respond({
          type: 'get_agent_state_response',
          config: {
            commands: this._getCommandsForProvider(),
            models: this._getModelsForProvider(),
            effortLevels: this._getEffortLevelsForProvider(),
            permissionModes: this._getPermissionModesForProvider(),
            account: { tokenSource: 'api_key', subscriptionType: 'pro' },
          },
        });
        break;
      case 'subscription':
        respond({
          type: 'subscription_response',
          subscription: { active: true, planType: 'max_5x', status: 'active' },
        });
        break;
      case 'auth_status':
        respond({
          type: 'auth_status_response',
          authenticated: true,
          hasActiveSubscription: true,
          accountType: 'max_5x',
          planType: 'max_5x',
        });
        break;
      // No-op handlers
      case 'login':
        respond({ type: 'login_response', authStatus: null });
        break;
      case 'list_remote_sessions':
        respond({ type: 'list_remote_sessions_response', sessions: [] });
        break;
      case 'get_current_selection':
        respond({ type: 'get_current_selection_response', selection: null });
        break;
      case 'get_asset_uris':
        respond({ type: 'get_asset_uris_response', assetUris: {} });
        break;
      case 'get_mcp_servers':
        respond({ type: 'get_mcp_servers_response', servers: [] });
        break;
      case 'list_files_request':
        respond({ type: 'list_files_response', files: [] });
        break;
      case 'list_marketplaces':
        respond({ type: 'list_marketplaces_response', marketplaces: [], plugins: [] });
        break;
      case 'show_notification':
        respond({ type: 'show_notification_response', buttonValue: undefined });
        break;
      case 'rename_tab':
        respond({ type: 'rename_tab_response' });
        break;
      case 'update_session_state':
        respond({ type: 'update_session_state_response' });
        break;
      case 'check_git_status':
        respond({ type: 'check_git_status_response', hasUncommittedChanges: false });
        break;
      case 'generate_session_title':
        respond({ type: 'generate_session_title_response', title: 'Chat' });
        break;
      case 'apply_settings': {
        const settings = request.settings || {};
        if (settings.effortLevel) {
          // Persist to config (source of truth)
          setAgentEffort(this.agentId, settings.effortLevel);
          // Update active connections for providers that support mid-session changes
          for (const [, entry] of this.connections) {
            if (entry.conn) entry.conn.effortLevel = settings.effortLevel;
          }
          if (this.provider?.setThinkingLevel) {
            for (const [, entry] of this.connections) {
              if (entry.conn) this.provider.setThinkingLevel(entry.conn, settings.effortLevel);
            }
          }
          console.log(`[session] Effort level set to: ${settings.effortLevel}`);
        }
        respond({ type: 'apply_settings_response' });
        break;
      }
      case 'request_usage_update':
        respond({ type: 'request_usage_update_response' });
        break;
      case 'rewind_code':
        respond({ type: 'rewind_code_response' });
        break;
      default:
        respond({ type: request.type + '_response' });
        break;
    }
  }

  // ── Provider event → Frontend protocol ──

  _handleProviderEvent(channelId, event) {
    // Track whether content_block_start was sent for streaming
    if (!this._turnState) this._turnState = {};

    // For non-Claude providers, translate internal events to the frontend protocol
    // Debug: uncomment to trace events
    // console.log(`[event] ${channelId.slice(0, 12)} ← ${event.type}`);
    switch (event.type) {
      case 'turn_start':
        this._turnState[channelId] = { blockStarted: false, thinkingBlockStarted: false, contentBlocks: [], _currentText: '', _currentThinking: '' };
        this._updateState('thinking');
        this.send({
          type: 'io_message',
          channelId,
          message: { type: 'message_start', message: { role: 'assistant' } },
        });
        break;

      case 'text_delta': {
        this._updateState('responding');
        const ts = this._turnState[channelId];
        if (ts && !ts.blockStarted) {
          this.send({
            type: 'io_message',
            channelId,
            message: { type: 'content_block_start', content_block: { type: 'text', text: '' } },
          });
          ts.blockStarted = true;
        }
        if (ts) ts._currentText += event.text;
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'content_block_delta',
            delta: { type: 'text_delta', text: event.text },
          },
        });
        break;
      }

      case 'text_done': {
        const ts2 = this._turnState[channelId];
        if (ts2) {
          if (ts2._currentText) ts2.contentBlocks.push({ type: 'text', text: ts2._currentText });
          ts2._currentText = '';
          ts2.blockStarted = false;
        }
        this.send({
          type: 'io_message',
          channelId,
          message: { type: 'content_block_stop' },
        });
        break;
      }

      case 'thinking_delta': {
        this._updateState('thinking');
        console.log(`[thinking] ${this.agentId}: thinking_delta len=${event.text?.length}`);
        const tst = this._turnState[channelId];
        if (tst && !tst.thinkingBlockStarted) {
          this.send({
            type: 'io_message',
            channelId,
            message: { type: 'content_block_start', content_block: { type: 'thinking', thinking: '' } },
          });
          tst.thinkingBlockStarted = true;
        }
        if (tst) tst._currentThinking += event.text;
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'content_block_delta',
            delta: { type: 'thinking_delta', thinking: event.text },
          },
        });
        break;
      }

      case 'thinking_done': {
        const tst2 = this._turnState[channelId];
        console.log(`[thinking] ${this.agentId}: thinking_done, started=${tst2?.thinkingBlockStarted}, accumulated=${tst2?._currentThinking?.length}`);
        if (tst2?.thinkingBlockStarted) {
          if (tst2._currentThinking) tst2.contentBlocks.push({ type: 'thinking', thinking: tst2._currentThinking });
          tst2._currentThinking = '';
          this.send({
            type: 'io_message',
            channelId,
            message: { type: 'content_block_stop' },
          });
          tst2.thinkingBlockStarted = false;
        }
        break;
      }

      case 'tool_start': {
        this._updateState('tool_call', event.name);
        const tsTool = this._turnState[channelId];
        if (tsTool) {
          // Flush any pending text before the tool call
          if (tsTool._currentText) {
            tsTool.contentBlocks.push({ type: 'text', text: tsTool._currentText });
            tsTool._currentText = '';
          }
          tsTool.contentBlocks.push({ type: 'tool_use', id: event.id, name: event.name, input: event.input || {} });
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'content_block_start',
            content_block: {
              type: 'tool_use',
              id: event.id,
              name: event.name,
              input: event.input || {},
            },
          },
        });
        break;
      }

      case 'tool_result': {
        this._updateState('responding');
        const ts3 = this._turnState[channelId];
        if (ts3) {
          ts3.blockStarted = false;
          ts3._toolResults = ts3._toolResults || [];
          ts3._toolResults.push({ tool_use_id: event.id, content: event.output, is_error: event.isError });
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'user',
            message: {
              role: 'user',
              content: [
                {
                  type: 'tool_result',
                  tool_use_id: event.id,
                  content: event.output,
                  is_error: event.isError,
                },
              ],
            },
          },
        });
        break;
      }

      case 'command_start': {
        this._updateState('tool_call', 'Bash');
        const tsCmd = this._turnState[channelId];
        if (tsCmd) {
          if (tsCmd._currentText) {
            tsCmd.contentBlocks.push({ type: 'text', text: tsCmd._currentText });
            tsCmd._currentText = '';
          }
          tsCmd.contentBlocks.push({ type: 'tool_use', id: event.id, name: 'Bash', input: { command: event.command } });
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'content_block_start',
            content_block: {
              type: 'tool_use',
              id: event.id,
              name: 'Bash',
              input: { command: event.command },
            },
          },
        });
        break;
      }

      case 'command_output':
        // Accumulate output for the tool result
        if (!this._commandOutputs) this._commandOutputs = {};
        this._commandOutputs[event.id] = (this._commandOutputs[event.id] || '') + event.output;
        break;

      case 'command_done': {
        this._updateState('responding');
        const ts4 = this._turnState[channelId];
        if (ts4) ts4.blockStarted = false;
        const cmdOutput = this._commandOutputs?.[event.id] || '';
        if (this._commandOutputs) delete this._commandOutputs[event.id];
        const resultText = cmdOutput
          ? cmdOutput.trim() + '\n\nExit code: ' + event.exitCode
          : 'Exit code: ' + event.exitCode;
        // Accumulate tool result for session write
        if (ts4) {
          ts4._toolResults = ts4._toolResults || [];
          ts4._toolResults.push({ tool_use_id: event.id, content: resultText, is_error: event.exitCode !== 0 });
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'user',
            message: {
              role: 'user',
              content: [
                {
                  type: 'tool_result',
                  tool_use_id: event.id,
                  content: resultText,
                  is_error: event.exitCode !== 0,
                },
              ],
            },
          },
        });
        break;
      }

      case 'file_change': {
        const toolName = event.operation === 'create' ? 'Write' : event.operation === 'delete' ? 'Bash' : 'Edit';
        this._updateState('tool_call', toolName);
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'content_block_start',
            content_block: {
              type: 'tool_use',
              id: `file-${Date.now()}`,
              name: toolName,
              input: { file_path: event.path },
            },
          },
        });
        break;
      }

      case 'turn_complete': {
        this._updateState('idle');
        const tsDone = this._turnState[channelId];
        if (this.providerName === 'claude') {
          const blocks = tsDone?.contentBlocks || [];
          const thinkingCount = blocks.filter(b => b.type === 'thinking').length;
          const thinkingLens = blocks.filter(b => b.type === 'thinking').map(b => (b.thinking||'').length);
          console.log(`[turn_complete] ${this.agentId} provider=${this.providerName} tsDone=${!!tsDone} blocks=${blocks.length} thinking=${thinkingCount} lens=${thinkingLens}`);
        }
        if (tsDone && this.providerName !== 'claude') {
          // Write accumulated assistant message to session JSONL (non-Claude providers)
          // Flush any trailing text
          if (tsDone._currentText) tsDone.contentBlocks.push({ type: 'text', text: tsDone._currentText });
          if (tsDone.contentBlocks.length > 0) {
            this._writeSessionEntry({ type: 'assistant', message: { role: 'assistant', content: tsDone.contentBlocks } });
          }
          // Write tool results as a user message (matching Claude JSONL format)
          if (tsDone._toolResults?.length > 0) {
            this._writeSessionEntry({
              type: 'user',
              message: { role: 'user', content: tsDone._toolResults.map((tr) => ({ type: 'tool_result', tool_use_id: tr.tool_use_id, content: tr.content, is_error: tr.is_error })) },
            });
          }
        } else if (tsDone && this.providerName === 'claude') {
          // Claude writes its own JSONL but redacts thinking content.
          // Save thinking separately so it can be restored on history load.
          const thinkingBlocks = tsDone.contentBlocks.filter((b) => b.type === 'thinking' && b.thinking);
          if (thinkingBlocks.length > 0) {
            this._writeSessionEntry({ type: 'thinking_cache', blocks: thinkingBlocks, timestamp: new Date().toISOString() });
          }
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'result',
            subtype: 'success',
            usage: event.usage
              ? {
                  input_tokens: event.usage.inputTokens,
                  output_tokens: event.usage.outputTokens,
                }
              : undefined,
          },
        });
        break;
      }

      case 'turn_error':
        this._updateState('error');
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'result',
            subtype: 'error',
            error: event.message,
          },
        });
        break;

      case 'session_ready': {
        const entry = this.connections.get(channelId);
        if (entry && event.sessionId) {
          entry.sessionId = event.sessionId;
          // Persist to session registry
          setAgentSession(this.agentId, this.providerName, event.sessionId);
        }
        this.send({
          type: 'io_message',
          channelId,
          message: {
            type: 'system',
            subtype: 'init',
            session_id: event.sessionId,
          },
        });
        break;
      }

      case 'resume_failed':
        // Session ID was stale — re-queue last message and relaunch fresh
        console.log(`[session] Resume failed for ${this.agentId}, relaunching fresh`);
        this._resumeRetrying = true;
        if (this._lastSentMessage) {
          if (!this._pendingMessages.has(channelId)) this._pendingMessages.set(channelId, []);
          this._pendingMessages.get(channelId).push(this._lastSentMessage);
          this._lastSentMessage = null;
        }
        this.connections.delete(channelId);
        this._launching = false;
        this.launchProvider({ channelId, resume: undefined, cwd: this.cwd });
        break;

      case 'session_closed':
        // Skip if we already relaunched from resume_failed (new conn is stored at this channelId)
        if (this._resumeRetrying) {
          this._resumeRetrying = false;
          break;
        }
        this._updateState('offline');
        this.send({
          type: 'close_channel',
          channelId,
          error: event.reason !== 'normal' ? event.reason : undefined,
        });
        this.connections.delete(channelId);
        break;

      case 'permission_request':
        // Auto-approve (bypass mode)
        if (this.provider) {
          this.provider.respondPermission(this.connections.get(channelId)?.conn, event.id, true);
        }
        break;

      case 'usage_update': {
        // Only merge Anthropic polled data for Claude sessions
        const polled = this.providerName === 'claude' ? getPolledUsage() : null;
        const merged = { ...this.lastUsage, ...(polled || {}), ...event.usage };
        // Compute context % from token counts — always recompute, cap at 100
        // (context window compacts old messages, so usage can't truly exceed 100%)
        if (merged.totalTokens) {
          const ctx = this._getContextWindowForModel();
          merged.contextPercent = Math.min(100, Math.round((merged.totalTokens / ctx) * 100));
        }
        if (merged.contextPercent != null) {
          merged.contextPercent = Math.max(0, Math.min(100, merged.contextPercent));
        }
        this.lastUsage = merged;
        this.send({
          type: 'request',
          channelId: '',
          requestId: crypto.randomUUID(),
          request: { type: 'usage_update', utilization: this.lastUsage },
        });
        break;
      }
    }
  }

  _getBackendConfig() {
    return getBackendsConfig()[this.providerName] || {};
  }

  _getCommandsForProvider() {
    return this._getBackendConfig().commands || [];
  }

  _getModelsForProvider() {
    const cfg = this._getBackendConfig();
    const hasEffort = (cfg.effortLevels || []).length > 0;
    return (cfg.models || []).map((m) => ({
      value: m.id,
      displayName: m.label || m.id,
      supportsEffort: hasEffort,
      supportsAutoMode: this._getBackendConfig().supportsAutoMode || false,
    }));
  }

  _getEffortLevelsForProvider() {
    const levels = this._getBackendConfig().effortLevels || [];
    return levels.map((l) => ({ value: l, label: l.charAt(0).toUpperCase() + l.slice(1) }));
  }

  _getPermissionModesForProvider() {
    return this._getBackendConfig().permissionModes || [];
  }

  _getContextWindowForModel() {
    const model = getAgentModel(this.agentId);
    const cfg = this._getBackendConfig();
    const match = (cfg.models || []).find((m) => m.id === model);
    if (match?.contextWindow) return match.contextWindow;
    // Fallback: first model's context window or 200k
    return cfg.models?.[0]?.contextWindow || 200000;
  }

  _getPermissionConfigForProvider() {
    const modes = this._getBackendConfig().permissionModes || [];
    const hasBypass = modes.some((m) => m.id === 'bypassPermissions');
    return {
      permissionMode: 'bypassPermissions',
      allowBypass: hasBypass,
    };
  }

  // Write a message entry to the session JSONL file (for non-Claude providers)
  _writeSessionEntry(entry) {
    try {
      const hashed = hashProjectPath(this.cwd);
      const conn = [...this.connections.values()][0]?.conn;
      const sessionId = conn?.sessionId || conn?.threadId;
      if (!sessionId) return;
      const dir = join(homedir(), '.claude', 'projects', hashed);
      if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
      const filePath = join(dir, `${sessionId}.jsonl`);
      appendFileSync(filePath, JSON.stringify({ ...entry, timestamp: new Date().toISOString() }) + '\n');
    } catch {}
  }

  cleanup() {
    for (const [, entry] of this.connections) {
      if (entry.unsub) entry.unsub();
      if (this.provider) this.provider.close(entry.conn);
    }
    this.connections.clear();
  }
}
