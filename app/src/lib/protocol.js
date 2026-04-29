/**
 * Protocol layer — clean async API over the WebSocket.
 */

import { send as wsSend, onMessage, switchAgent as wsSwitchAgent } from './ws.js';
import './theme.js';

let initialized = false;
const pendingRequests = new Map();
const listeners = new Map();

export function initProtocol() {
  if (initialized) return;
  initialized = true;
  onMessage((msg) => {
    if (msg.type === 'response' && msg.requestId) {
      const entry = pendingRequests.get(msg.requestId);
      if (entry) {
        pendingRequests.delete(msg.requestId);
        entry.resolve(msg.response);
      }
    }
    const set = listeners.get(msg.type);
    if (set) for (const fn of set) fn(msg);
    const wild = listeners.get('*');
    if (wild) for (const fn of wild) fn(msg);
  });
}

export function send(msg) {
  wsSend(msg);
}

export function request(type, payload = {}) {
  return new Promise((resolve, reject) => {
    const id = crypto.randomUUID();
    pendingRequests.set(id, { resolve, reject });
    send({ type: 'request', requestId: id, request: { type, ...payload } });
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error(`Request ${type} timed out`));
      }
    }, 30000);
  });
}

export function on(type, callback) {
  if (!listeners.has(type)) listeners.set(type, new Set());
  listeners.get(type).add(callback);
  return () => listeners.get(type)?.delete(callback);
}

// ── High-level API ──

export function launchAgent(
  channelId,
  { resume, agentId, provider, conversationId, replayAfterSeq, historyReloaded } = {},
) {
  send({ type: 'launch', channelId, resume, agentId, provider, conversationId, replayAfterSeq, historyReloaded });
}

export function sendMessage(channelId, message, agentId, conversationId) {
  send({ type: 'io_message', channelId, agentId, conversationId, message, done: true });
}

export function interrupt(channelId, agentId, conversationId) {
  send({ type: 'interrupt', channelId, agentId, conversationId });
}

export function closeChannel(channelId, agentId, conversationId) {
  send({ type: 'close_channel', channelId, agentId, conversationId });
}

export async function listSessions() {
  const res = await request('list_sessions_request');
  return res?.sessions || [];
}

/** Get config (models, commands) from the current agent's backend. Stores on window for UI components. */
export async function getAgentState() {
  const res = await request('get_agent_state');
  if (res?.config?.models) {
    window._clawmuxModels = res.config.models.map((m) => ({
      id: m.value || m.id,
      label: m.displayName || m.value || m.id,
      desc: '',
    }));
  }
  if (res?.config?.commands) {
    window._clawmuxCommands = res.config.commands.map((c) => ({
      cmd: c.name?.startsWith('/') ? c.name : `/${c.name || c.value || ''}`,
      desc: c.description || c.desc || '',
      action: 'send',
    }));
  } else {
    window._clawmuxCommands = null;
  }
  window._clawmuxEffortLevels = res?.config?.effortLevels || null;
  window._clawmuxPermissionModes = res?.config?.permissionModes || null;
  return res;
}

export function respondToRequest(requestId, response) {
  send({ type: 'response', requestId, response });
}

export function switchAgent(agentId, provider) {
  wsSwitchAgent(agentId, provider);
}
