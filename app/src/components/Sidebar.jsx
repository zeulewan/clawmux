import React, { useState, useCallback, useEffect, useSyncExternalStore } from 'react';
import ReactDOM from 'react-dom';
import {
  subscribe,
  getActiveSession,
  switchToAgent,
  getCurrentAgent,
  getCurrentProvider,
  getCurrentModel,
  changeBackend,
  reloadConfig,
} from '../state/sessions.js';
import {
  subscribe as subscribeMonitor,
  getSnapshot as getMonitorSnapshot,
  subscribeTick,
  getTick,
  statusStyle,
  shortenTool,
  ctxColor,
  timeAgo,
} from '../state/monitor.js';

/**
 * Sidebar — agents list with backend badges.
 * All config comes from the sessions store (which reads from server).
 */

// Config fetch for sidebar-specific data (agent list, backends, labels)
async function fetchConfig() {
  const res = await fetch('/api/config');
  return res.json();
}

function getAgentsFromConfig(cfg) {
  const def = cfg?.backends?._default || 'claude';
  return (cfg?.agents?.agents || []).map((a) => ({
    id: a.name.toLowerCase(),
    name: a.name,
    backend: a.backend || cfg?.agents?.defaults?.backend || def,
  }));
}

function getBackendsFromConfig(cfg) {
  return Object.entries(cfg?.backends || {})
    .filter(([k, v]) => !k.startsWith('_') && v.enabled)
    .map(([k]) => k);
}

function getBackendLabelsFromConfig(cfg) {
  const labels = {};
  for (const [k, v] of Object.entries(cfg?.backends || {})) {
    if (k.startsWith('_') || typeof v !== 'object') continue;
    labels[k] = v.label || k;
  }
  return labels;
}

function BackendBadge({ agentId, currentBackend, backends, backendLabels, onRefresh }) {
  const [open, setOpen] = useState(false);
  const [hovering, setHovering] = useState(false);
  const closeTimer = React.useRef(null);
  const currentAgent = useSyncExternalStore(subscribe, getCurrentAgent);

  const resolved =
    !currentBackend || currentBackend === 'default' ? Object.keys(backendLabels)[0] || 'claude' : currentBackend;
  const label = backendLabels[resolved] || resolved;

  const cancelClose = () => {
    if (closeTimer.current) {
      clearTimeout(closeTimer.current);
      closeTimer.current = null;
    }
  };
  const scheduleClose = () => {
    cancelClose();
    closeTimer.current = setTimeout(() => {
      setHovering(false);
      setOpen(false);
    }, 150);
  };

  useEffect(() => {
    if (!open) return;
    const dismiss = (e) => {
      if (!e.target.closest?.('.backend-badge-wrap')) setOpen(false);
    };
    document.addEventListener('pointerdown', dismiss);
    return () => document.removeEventListener('pointerdown', dismiss);
  }, [open]);
  useEffect(() => () => cancelClose(), []);

  return (
    <span
      className="backend-badge-wrap"
      onMouseEnter={() => {
        cancelClose();
        setHovering(true);
      }}
      onMouseLeave={scheduleClose}
    >
      <span
        className={`agent-backend-badge ${hovering ? 'hoverable' : ''}`}
        onClick={(e) => {
          e.stopPropagation();
          setOpen(!open);
        }}
      >
        {label}
      </span>
      {open && (
        <div className="backend-picker-dropdown">
          {(backends || []).map((b) => (
            <button
              key={b}
              className={`backend-picker-option ${b === currentBackend ? 'active' : ''}`}
              onClick={async (e) => {
                e.stopPropagation();
                setOpen(false);
                try {
                  if (agentId !== currentAgent) switchToAgent(agentId);
                  await changeBackend(agentId, b);
                  if (onRefresh) onRefresh();
                } catch (err) {
                  console.error('[sidebar] backend switch failed:', err);
                }
              }}
            >
              {backendLabels[b] || b}
            </button>
          ))}
        </div>
      )}
    </span>
  );
}

function ContextMenu({ x, y, items, onClose }) {
  useEffect(() => {
    const timer = setTimeout(() => {
      const dismiss = (e) => {
        if (e.target.closest?.('.sidebar-context-menu')) return;
        onClose();
      };
      document.addEventListener('pointerdown', dismiss);
      document.addEventListener('contextmenu', dismiss);
      return () => {
        document.removeEventListener('pointerdown', dismiss);
        document.removeEventListener('contextmenu', dismiss);
      };
    }, 50);
    return () => clearTimeout(timer);
  }, [onClose]);

  return ReactDOM.createPortal(
    <div className="sidebar-context-menu" style={{ top: y, left: x }}>
      {items.map((item, i) =>
        item.separator ? (
          <div key={i} className="sidebar-context-separator" />
        ) : (
          <button
            key={i}
            className="sidebar-context-item"
            onClick={() => {
              item.action();
              onClose();
            }}
          >
            {item.label}
          </button>
        ),
      )}
    </div>,
    document.body,
  );
}

export function Sidebar({ collapsed, onToggle, onShowSettings, showMonitor, onToggleMonitor }) {
  useSyncExternalStore(subscribe, getActiveSession);
  const currentAgent = useSyncExternalStore(subscribe, getCurrentAgent);
  // Subscribe to the shared monitor store — replaces /api/status polling.
  const monitor = useSyncExternalStore(subscribeMonitor, getMonitorSnapshot);
  // 1Hz tick so the activity timestamps in tooltips refresh.
  useSyncExternalStore(subscribeTick, getTick);
  const [search, setSearch] = useState('');
  const [contextMenu, setContextMenu] = useState(null);
  const [agents, setAgents] = useState([]);
  const [backends, setBackends] = useState([]);
  const [backendLabels, setBackendLabels] = useState({});

  // Load config from server — refresh on agent change
  const loadConfig = useCallback(() => {
    fetchConfig().then((cfg) => {
      setAgents(getAgentsFromConfig(cfg));
      setBackends(getBackendsFromConfig(cfg));
      setBackendLabels(getBackendLabelsFromConfig(cfg));
    });
  }, []);

  useEffect(() => {
    loadConfig();
  }, [currentAgent, loadConfig]);

  const filteredAgents = search ? agents.filter((a) => a.name.toLowerCase().includes(search.toLowerCase())) : agents;

  const handleAgentClick = useCallback(
    (agentId) => {
      switchToAgent(agentId);
      if (window.innerWidth < 768 && onToggle) onToggle();
    },
    [onToggle],
  );

  if (collapsed)
    return (
      <div className="sidebar-collapsed">
        <button className="sidebar-toggle-btn" onClick={onToggle} title="Expand sidebar">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M3 12h18M3 6h18M3 18h18" />
          </svg>
        </button>
      </div>
    );

  return (
    <div className="sidebar-expanded">
      <div className="sidebar-header">
        <button className="sidebar-toggle-btn" onClick={onToggle} title="Collapse sidebar">
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M3 12h18M3 6h18M3 18h18" />
          </svg>
        </button>
        <div className="sidebar-title">Agents</div>
        {onToggleMonitor && (
          <button
            className={`sidebar-monitor-btn ${showMonitor ? 'active' : ''}`}
            onClick={onToggleMonitor}
            title={showMonitor ? 'Close monitor' : 'Open monitor'}
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="4" width="18" height="12" rx="1" />
              <path d="M8 20h8M12 16v4" />
            </svg>
          </button>
        )}
        {onShowSettings && (
          <button className="sidebar-monitor-btn" onClick={onShowSettings} title="Settings">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <circle cx="12" cy="12" r="3" />
              <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
            </svg>
          </button>
        )}
      </div>

      <div className="sidebar-search">
        <input type="text" placeholder="Search agents..." value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>

      <div className="sidebar-conversations">
        {filteredAgents.map((agent) => {
          // Look up live monitor data (key matching is loose — backend stores by name lowercase or the agent id).
          const live =
            monitor.agents[agent.id] ||
            monitor.agents[agent.name] ||
            Object.values(monitor.agents).find((a) => a?.name?.toLowerCase() === agent.id) ||
            null;
          const status = live?.status || 'offline';
          const st = statusStyle[status] || statusStyle.offline;
          const alive = status !== 'offline';
          const ctx = live?.contextPercent;
          const tool = status === 'tool_call' ? shortenTool(live?.currentTool) : '';
          const pulsing = status === 'responding' || status === 'thinking';
          const tipLines = [
            `${st.label}${live?.model ? `  ·  ${live.model}` : ''}`,
            ctx != null ? `ctx: ${ctx}%` : null,
            live?.currentTool ? `tool: ${shortenTool(live.currentTool)}` : null,
            alive && live?.lastActivity ? `last: ${timeAgo(live.lastActivity)}` : null,
            live?.sessionId ? `sid: ${live.sessionId.slice(0, 16)}` : null,
          ].filter(Boolean);
          return (
            <button
              key={agent.id}
              className={`sidebar-convo ${agent.id === currentAgent ? 'active' : ''}`}
              onClick={() => handleAgentClick(agent.id)}
              title={tipLines.join('\n')}
              onContextMenu={(e) => {
                e.preventDefault();
                const items = [];
                if (alive) {
                  items.push({
                    label: 'Terminate',
                    action: () => {
                      fetch('/api/terminate', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ agentId: agent.id }),
                      }).catch(() => {});
                    },
                  });
                }
                setContextMenu({ x: e.clientX, y: e.clientY, items });
              }}
            >
              <span
                className={`sidebar-status-dot ${pulsing ? 'pulsing' : ''}`}
                style={{ background: st.color, opacity: alive ? 1 : 0.3 }}
              />
              <span className="convo-title-wrap">
                <span className="convo-title">{agent.name}</span>
                {tool && <span className="convo-tool-inline">{tool}</span>}
              </span>
              {ctx != null && (
                <span className="convo-ctx" style={{ color: ctxColor(ctx) }}>
                  {ctx}%
                </span>
              )}
              <BackendBadge
                agentId={agent.id}
                currentBackend={agent.backend}
                backends={backends}
                backendLabels={backendLabels}
                onRefresh={loadConfig}
              />
            </button>
          );
        })}
        {filteredAgents.length === 0 && <div className="sidebar-empty">No matches</div>}
      </div>

      {contextMenu && (
        <ContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          items={contextMenu.items}
          onClose={() => setContextMenu(null)}
        />
      )}
    </div>
  );
}
