/**
 * Monitor store — single SSE connection to /api/monitor/stream shared across
 * the whole app. Components subscribe via useSyncExternalStore.
 *
 * Snapshot shape: { agents: {agentId: {name, backend, model, status, ...}}, usage: {anthropic, openai}, connected }
 */

let state = { agents: {}, usage: {}, connected: false };
const listeners = new Set();
let es = null;
let reconnectTimer = null;
// Tick clock so timeAgo() consumers re-render every second without each
// component spinning its own interval.
let tickValue = 0;
let tickInterval = null;

function notify() {
  // Bump a shallow ref so React sees a new object identity.
  state = { ...state };
  for (const fn of listeners) fn();
}

function connect() {
  if (es) return;
  try {
    es = new EventSource('/api/monitor/stream');
  } catch {
    scheduleReconnect();
    return;
  }
  es.onopen = () => {
    state.connected = true;
    notify();
  };
  es.onerror = () => {
    state.connected = false;
    notify();
    if (es) {
      es.close();
      es = null;
    }
    scheduleReconnect();
  };
  es.onmessage = (ev) => {
    try {
      const data = JSON.parse(ev.data);
      if (data._usage) {
        state.usage = data._usage;
        delete data._usage;
      }
      state.agents = { ...state.agents, ...data };
      notify();
    } catch {}
  };
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, 3000);
}

function startTick() {
  if (tickInterval) return;
  tickInterval = setInterval(() => {
    tickValue++;
    // Don't reshape state — listeners that only need agents/usage won't re-run.
    // For timeAgo refresh consumers, expose getTick separately.
    for (const fn of tickListeners) fn();
  }, 1000);
}

const tickListeners = new Set();

export function subscribe(fn) {
  listeners.add(fn);
  if (listeners.size === 1) connect();
  return () => {
    listeners.delete(fn);
  };
}

export function getSnapshot() {
  return state;
}

export function subscribeTick(fn) {
  tickListeners.add(fn);
  if (tickListeners.size === 1) startTick();
  return () => {
    tickListeners.delete(fn);
    if (tickListeners.size === 0 && tickInterval) {
      clearInterval(tickInterval);
      tickInterval = null;
    }
  };
}

export function getTick() {
  return tickValue;
}

// Helpers reused across Monitor + Sidebar
export const statusStyle = {
  responding: { color: '#22c55e', icon: '\u25cf', label: 'responding' },
  thinking: { color: '#eab308', icon: '\u25d0', label: 'thinking' },
  tool_call: { color: '#a855f7', icon: '\u25c6', label: 'tool_call' },
  idle: { color: '#7aa2c7', icon: '\u25cb', label: 'idle' },
  offline: { color: '#5c6370', icon: '\u00b7', label: 'offline' },
  error: { color: '#ef4444', icon: '\u2715', label: 'error' },
};

export const backendColor = {
  claude: '#d97757',
  codex: '#10a37f',
  pi: '#c364c5',
  opencode: '#22d3ee',
};

export function timeAgo(ts) {
  if (!ts) return '';
  const secs = Math.floor((Date.now() - ts) / 1000);
  if (secs < 5) return 'just now';
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  return `${Math.floor(secs / 3600)}h ago`;
}

export function shortenTool(t) {
  if (!t) return '';
  const m = t.match(/^mcp__([^_]+)__(.+)$/);
  return m ? `${m[1]}.${m[2]}` : t;
}

export function ctxColor(pct) {
  if (pct == null) return 'inherit';
  if (pct > 80) return '#ef4444';
  if (pct > 50) return '#eab308';
  return '#22c55e';
}
