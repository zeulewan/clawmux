/**
 * Sessions store.
 *
 * Key design: agent sessions stay alive when you switch away.
 * Each agent has its own sessions array + activeSession.
 * Switching agents = changing which agent's data is rendered.
 * No dispose, no re-launch, no lost messages.
 */

import { createSession } from './session.js';
import {
  listSessions as listSessionsRPC,
  request,
  initProtocol,
  switchAgent as switchAgentWS,
  interrupt as interruptChannel,
  on,
  getAgentState,
} from '../lib/protocol.js';

// ── Store ──────────────────────────────────────────────────────

const store = {
  focusedAgent: null,
  config: null,
  // Per-agent session state — sessions stay alive when not focused
  agents: new Map(), // agentId → { sessions: [], activeSession: null }
};

function _getAgentState(agentId) {
  if (!store.agents.has(agentId)) {
    store.agents.set(agentId, { sessions: [], activeSession: null });
  }
  return store.agents.get(agentId);
}

function _focused() {
  return store.focusedAgent ? _getAgentState(store.focusedAgent) : { sessions: [], activeSession: null };
}

const _listeners = new Set();
function notify() {
  for (const fn of _listeners) fn();
}

function _conversationKey(agentId, backend) {
  return agentId && backend ? `cmx-conversation-${agentId}-${backend}` : null;
}

function _resolveConversationId({ agentId, backend, sessionId } = {}) {
  if (sessionId) {
    const bySession = localStorage.getItem(`cmx-conversation-session-${sessionId}`);
    if (bySession) return bySession;
  }
  const byBackend = _conversationKey(agentId, backend);
  if (byBackend) {
    const stored = localStorage.getItem(byBackend);
    if (stored) return stored;
  }
  if (agentId) {
    const fallback = localStorage.getItem(`cmx-conversation-${agentId}`);
    if (fallback) return fallback;
  }
  return sessionId ? `session:${sessionId}` : null;
}

// ── Public getters ─────────────────────────────────────────────

export function subscribe(fn) {
  _listeners.add(fn);
  return () => _listeners.delete(fn);
}
export function getSessions() {
  return _focused().sessions;
}
export function getActiveSession() {
  return _focused().activeSession;
}
export function getCurrentAgent() {
  return store.focusedAgent;
}

export function getCurrentProvider() {
  if (!store.config || !store.focusedAgent) return 'claude';
  const agents = store.config.agents?.agents || [];
  const agent = agents.find((a) => a.name.toLowerCase() === store.focusedAgent);
  return agent?.backend || store.config.agents?.defaults?.backend || store.config.backends?._default || 'claude';
}

export function getCurrentModel() {
  if (!store.config || !store.focusedAgent) return '';
  const agents = store.config.agents?.agents || [];
  const agent = agents.find((a) => a.name.toLowerCase() === store.focusedAgent);
  const model = agent?.model || store.config.agents?.defaults?.model || '';
  const backend = agent?.backend || store.config.agents?.defaults?.backend || store.config.backends?._default;
  const bcfg = store.config.backends?.[backend];
  // Resolve "default" to the actual model label
  if (model === 'default' && bcfg) {
    const defaultId = bcfg.defaultModel || bcfg.models?.[0]?.id;
    const match = bcfg.models?.find((m) => m.id === defaultId);
    return match?.label || defaultId || '';
  }
  // For non-default, show label if available
  if (bcfg?.models) {
    const match = bcfg.models.find((m) => m.id === model);
    if (match?.label) return match.label;
  }
  return model;
}

export function getModelsForCurrentBackend() {
  if (!store.config) return [];
  const backend = getCurrentProvider();
  const cfg = store.config.backends?.[backend];
  if (!cfg?.models) return [];
  return cfg.models.map((m) => ({ id: m.id, label: m.label || m.id }));
}

// ── Config ──���─────────────────────────────��────────────────────

export async function reloadConfig() {
  try {
    const res = await fetch('/api/config');
    store.config = await res.json();
  } catch {}
  notify();
}

// ── Sessions ──────��────────────────────────────────────────────

export function createNewSession(opts = {}) {
  const state = _focused();
  const provider = opts.provider || getCurrentProvider();
  const session = createSession({
    ...opts,
    agentId: store.focusedAgent,
    provider,
  });
  session._models = getModelsForCurrentBackend();
  state.sessions.unshift(session);
  state.activeSession = session;
  session.launch();
  _persistSession();
  notify();
  return session;
}

export function activateSession(session) {
  const state = _focused();
  state.activeSession = session;
  _persistSession();
  notify();
}

export function resumeSession(sessionId, summary, provider) {
  const state = _focused();
  const existing = state.sessions.find((s) => s.sessionId === sessionId);
  if (existing) {
    state.activeSession = existing;
    _persistSession();
    notify();
    return existing;
  }
  const session = createSession({
    resume: sessionId,
    provider: provider || getCurrentProvider(),
    agentId: store.focusedAgent,
    conversationId:
      _resolveConversationId({
        agentId: store.focusedAgent,
        backend: provider || getCurrentProvider(),
        sessionId,
      }) || `session:${sessionId}`,
  });
  session._models = getModelsForCurrentBackend();
  if (summary) session.summary = summary;
  state.sessions.unshift(session);
  state.activeSession = session;
  request('get_session_request', { sessionId })
    .then((res) => {
      if (res?.messages?.length > 0) session.loadMessages(res.messages);
    })
    .catch(() => {});
  _persistSession();
  notify();
  return session;
}

// ── Agent switching (NO dispose — sessions stay alive) ─────────

export function switchToAgent(agentId) {
  if (agentId === store.focusedAgent) return;
  store.focusedAgent = agentId || null;
  localStorage.setItem('cmx-current-agent', agentId || '');
  switchAgentWS(agentId, getCurrentProvider());
  notify();
}

// ── Backend/model/effort changes ───��───────────────────────────

export async function changeBackend(agentId, backend) {
  await fetch(`/api/agents/${agentId}/backend`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ backend }),
  });
  await reloadConfig();
  // Server kills the old connection via killConnections().
  // Don't create a new session here — the existing session's next send()
  // calls launch() which re-reads the backend from config and relaunches.
  // If agent_switched already created a session, creating another would
  // produce duplicate channelIds.
  const state = _focused();
  if (state.activeSession) {
    state.activeSession._launched = false; // force relaunch on next send
    state.activeSession.provider = backend;
    state.activeSession.sessionId = null;
  }
  notify();
}

export async function changeModel(agentId, model) {
  await fetch(`/api/agents/${agentId}/model`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model }),
  });
  await reloadConfig();
  // Resume same session with new model (preserves history)
  if (agentId === store.focusedAgent) {
    const state = _focused();
    const sid = state.activeSession?.sessionId;
    if (sid) {
      resumeSession(sid, state.activeSession?.summary, getCurrentProvider()).launch();
    } else {
      createNewSession();
    }
  }
}

export async function changeEffort(agentId, effort) {
  await fetch(`/api/agents/${agentId}/effort`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ effort }),
  });
  await reloadConfig();
  request('apply_settings', { settings: { effortLevel: effort } }).catch(() => {});
}

// ── Init ────────────────────────────────────────────────���──────

export async function init() {
  await reloadConfig();
  initProtocol();
  getAgentState().catch(() => {});

  // Re-establish server-side channelId mapping on WS reconnect
  on('ws_reconnected', async () => {
    const state = _focused();
    if (state?.activeSession) {
      // Reset _launched so launch() actually sends the launch message,
      // re-establishing the channelId → agentId mapping on the new WS.
      // Without this, the server never maps the new WS to the session's
      // channelId, and streaming events (tool calls, outputs) are lost.
      state.activeSession._launched = false;
      state.activeSession.busy = false;
      state.activeSession._currentAssistantMessage = null;

      let historyReloaded = false;
      if (state.activeSession.sessionId) {
        try {
          const res = await request('get_session_request', { sessionId: state.activeSession.sessionId });
          if (res?.messages?.length > 0) {
            state.activeSession.loadMessages(res.messages);
            historyReloaded = true;
          }
        } catch {}
      }

      state.activeSession._historyReloadedOnReconnect = historyReloaded;
      state.activeSession.launch();
    }
  });

  // Handler for loading sessions when an agent is first focused
  on('agent_switched', async () => {
    const state = _focused();
    // Already has sessions — just refresh config
    if (state.sessions.length > 0 && state.activeSession) {
      setTimeout(() => getAgentState().catch(() => {}), 300);
      return;
    }
    // Load from server
    try {
      const saved = await listSessionsRPC();
      if (saved?.length > 0) {
        const backend = getCurrentProvider();
        // Read session ID from server registry (source of truth), fallback to localStorage
        const serverSid = store.config?.sessions?.[store.focusedAgent]?.[backend] || null;
        const backendKey = store.focusedAgent ? `cmx-session-${store.focusedAgent}-${backend}` : null;
        const fallbackKey = store.focusedAgent ? `cmx-session-${store.focusedAgent}` : null;
        const savedSid =
          serverSid ||
          (backendKey && localStorage.getItem(backendKey)) ||
          (fallbackKey && localStorage.getItem(fallbackKey)) ||
          null;
        const target = (savedSid && saved.find((s) => s.id === savedSid)) || saved[0];
        resumeSession(target.id, target.summary, target.provider).launch();
        setTimeout(() => getAgentState().catch(() => {}), 300);
        return;
      }
    } catch {}
    createNewSession().launch();
    setTimeout(() => getAgentState().catch(() => {}), 300);
  });

  on('agent_migrated', async (msg) => {
    await reloadConfig();
    if (msg.agentId !== store.focusedAgent) {
      notify();
      return;
    }
    const state = _focused();
    if (state.activeSession) {
      state.activeSession.provider = msg.toBackend;
      state.activeSession._launched = true;
      if (msg.sessionId) {
        state.activeSession.sessionId = msg.sessionId;
        localStorage.setItem(`cmx-conversation-session-${msg.sessionId}`, state.activeSession.conversationId);
        localStorage.setItem(`cmx-session-${msg.agentId}-${msg.toBackend}`, msg.sessionId);
        localStorage.setItem(`cmx-session-${msg.agentId}`, msg.sessionId);
      }
    }
    notify();
  });

  // Restore focused agent
  const agents = store.config?.agents?.agents || [];
  const firstAgent = agents[0]?.name?.toLowerCase() || 'adam';
  const savedAgent = localStorage.getItem('cmx-current-agent') || firstAgent;
  store.focusedAgent = savedAgent;
  localStorage.setItem('cmx-current-agent', savedAgent);
  switchAgentWS(savedAgent, getCurrentProvider());
}

// ── Persistence ────────────────────────────────────────────────

function _persistSession() {
  const state = _focused();
  if (state.activeSession?.conversationId && store.focusedAgent) {
    const backend = getCurrentProvider();
    const conversationId = state.activeSession.conversationId;
    localStorage.setItem(`cmx-conversation-${store.focusedAgent}`, conversationId);
    localStorage.setItem(`cmx-conversation-${store.focusedAgent}-${backend}`, conversationId);
    if (state.activeSession.sessionId) {
      localStorage.setItem(`cmx-conversation-session-${state.activeSession.sessionId}`, conversationId);
    }
  }
  if (state.activeSession?.sessionId && store.focusedAgent) {
    const backend = getCurrentProvider();
    localStorage.setItem(`cmx-session-${store.focusedAgent}-${backend}`, state.activeSession.sessionId);
    // Also keep the backend-agnostic key for backward compat
    localStorage.setItem(`cmx-session-${store.focusedAgent}`, state.activeSession.sessionId);
    localStorage.setItem('cmx-current-agent', store.focusedAgent);
  }
}
