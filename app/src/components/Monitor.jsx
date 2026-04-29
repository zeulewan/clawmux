import React, { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { switchToAgent } from '../state/sessions.js';
import {
  subscribe,
  getSnapshot,
  subscribeTick,
  getTick,
  statusStyle,
  backendColor,
  timeAgo,
  shortenTool,
  ctxColor,
} from '../state/monitor.js';

/**
 * Monitor — real-time agent dashboard. Mirrors the CLI `cmx monitor` view.
 * Subscribes to the shared monitor store. Click an agent row to inspect its
 * provider tail stream, with an explicit action to jump into chat.
 */

const RAW_TAIL_LIMIT = 200;
const RAW_TAIL_MAX = 400;

function UsageBar({ pct, width = 12 }) {
  const filled = pct == null ? 0 : Math.round((pct / 100) * width);
  const color = ctxColor(pct);
  return (
    <span style={{ fontFamily: 'monospace', color }}>
      [{'█'.repeat(filled)}
      {'░'.repeat(width - filled)}]
    </span>
  );
}

function pad(text, width) {
  const s = String(text || '');
  return s.length >= width ? s.slice(0, width) : s + ' '.repeat(width - s.length);
}

function formatTime(ts) {
  return new Date(ts || Date.now()).toTimeString().slice(0, 8);
}

function directionArrow(direction) {
  if (direction === 'out') return '→';
  if (direction === 'err') return '!';
  return '←';
}

function stringifyPayload(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function formatTailEvent(event, view) {
  if (!event) return '';
  if (view === 'json') return stringifyPayload(event);

  const prefix = `${formatTime(event.ts)} ${directionArrow(event.direction)} ${pad(event.transport || 'provider', 8)} `;
  if (view === 'summary') {
    const sid = event.sessionId ? ` ${String(event.sessionId).slice(0, 12)}` : '';
    return `${prefix}${event.summary || 'event'}${sid}`;
  }

  const body = event.raw || stringifyPayload(event.payload);
  const indent = ' '.repeat(prefix.length);
  return String(body)
    .split('\n')
    .map((line, idx) => (idx === 0 ? `${prefix}${line}` : `${indent}${line}`))
    .join('\n');
}

function TailPanel({ agentId, agent, view, onViewChange, onOpenChat, launching, launchError }) {
  const [events, setEvents] = useState([]);
  const [streamState, setStreamState] = useState('connecting');
  const [streamError, setStreamError] = useState('');
  const bodyRef = useRef(null);
  const stickToBottomRef = useRef(true);

  useEffect(() => {
    if (!agentId) return undefined;
    setEvents([]);
    setStreamState('connecting');
    setStreamError('');
    stickToBottomRef.current = true;

    const es = new EventSource(`/api/agents/${encodeURIComponent(agentId)}/raw/stream?limit=${RAW_TAIL_LIMIT}`);
    es.onmessage = (msg) => {
      try {
        const packet = JSON.parse(msg.data);
        setStreamState('live');
        setStreamError('');
        setEvents((prev) => {
          let next = prev;
          if (Array.isArray(packet.events)) next = packet.events;
          else if (packet.event) next = [...prev, packet.event];
          if (next.length > RAW_TAIL_MAX) next = next.slice(-RAW_TAIL_MAX);
          return next;
        });
      } catch (err) {
        setStreamError(err.message || 'Bad tail packet');
      }
    };
    es.onerror = () => {
      setStreamState((prev) => (prev === 'live' ? 'reconnecting' : 'connecting'));
    };
    return () => es.close();
  }, [agentId]);

  useEffect(() => {
    const node = bodyRef.current;
    if (node && stickToBottomRef.current) node.scrollTop = node.scrollHeight;
  }, [events, view, agentId]);

  const handleScroll = () => {
    const node = bodyRef.current;
    if (!node) return;
    const delta = node.scrollHeight - node.scrollTop - node.clientHeight;
    stickToBottomRef.current = delta < 24;
  };

  const statusText = launching
    ? 'launching'
    : streamState === 'live'
      ? 'live'
      : streamState === 'reconnecting'
        ? 'reconnecting'
        : 'connecting';

  return (
    <div className="monitor-tail">
      <div className="monitor-tail-header">
        <div className="monitor-tail-head">
          <div className="monitor-tail-title">{agent?.name || agentId} Tail</div>
          <div className="monitor-tail-meta">
            <span>{agent?.backend || '-'}</span>
            <span>{agent?.model || ''}</span>
            <span>{statusText}</span>
            <span>{agent?.sessionId ? agent.sessionId.slice(0, 16) : 'no session'}</span>
          </div>
        </div>
        <div className="monitor-tail-controls">
          {['summary', 'raw', 'json'].map((mode) => (
            <button
              key={mode}
              className={`monitor-tail-btn ${view === mode ? 'active' : ''}`}
              onClick={() => onViewChange(mode)}
            >
              {mode}
            </button>
          ))}
          <button className="monitor-tail-btn monitor-tail-btn-primary" onClick={onOpenChat}>
            Open Chat
          </button>
        </div>
      </div>

      {(launchError || streamError) && <div className="monitor-tail-error">{launchError || streamError}</div>}

      <div className="monitor-tail-body" ref={bodyRef} onScroll={handleScroll}>
        {events.length === 0 ? (
          <div className="monitor-tail-empty">
            {launching
              ? `Launching ${agent?.name || agentId} and waiting for provider traffic...`
              : `No provider traffic for ${agent?.name || agentId} yet.`}
          </div>
        ) : (
          events.map((event) => (
            <pre key={event.id} className={`monitor-tail-line dir-${event.direction || 'in'}`}>
              {formatTailEvent(event, view)}
            </pre>
          ))
        )}
      </div>
    </div>
  );
}

export function Monitor({ onClose }) {
  const snap = useSyncExternalStore(subscribe, getSnapshot);
  // Subscribe to the 1Hz tick so timeAgo() refreshes.
  useSyncExternalStore(subscribeTick, getTick);
  const [selectedAgentId, setSelectedAgentId] = useState(null);
  const [tailView, setTailView] = useState('summary');
  const [launchingAgentId, setLaunchingAgentId] = useState(null);
  const [launchError, setLaunchError] = useState('');
  const [launchErrorAgentId, setLaunchErrorAgentId] = useState(null);

  const rows = useMemo(() => {
    return Object.entries(snap.agents)
      .filter(([k]) => k !== '_usage')
      .sort((a, b) => (a[1].name || '').localeCompare(b[1].name || ''));
  }, [snap.agents]);

  const selectedAgent = selectedAgentId ? snap.agents[selectedAgentId] || null : null;

  const counts = useMemo(() => {
    const all = rows.map(([, a]) => a);
    return {
      total: all.length,
      online: all.filter((a) => a.status !== 'offline').length,
      active: all.filter((a) => a.status !== 'offline' && a.status !== 'idle').length,
    };
  }, [rows]);

  const handleOpenChat = () => {
    if (!selectedAgentId) return;
    switchToAgent(selectedAgentId.toLowerCase());
    if (onClose) onClose();
  };

  const handleRowClick = async (agentId, agent) => {
    setLaunchError('');
    setLaunchErrorAgentId(null);
    setSelectedAgentId((prev) => (prev === agentId ? null : agentId));
    if (selectedAgentId === agentId) return;
    if (agent?.status !== 'offline' && agent?.sessionId) return;

    setLaunchingAgentId(agentId);
    try {
      const res = await fetch('/api/launch', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ agentId }),
      });
      const data = await res.json();
      if (!data.ok) {
        setLaunchError(data.error || `Failed to launch ${agent?.name || agentId}`);
        setLaunchErrorAgentId(agentId);
      }
    } catch (err) {
      setLaunchError(err.message || `Failed to launch ${agent?.name || agentId}`);
      setLaunchErrorAgentId(agentId);
    } finally {
      setLaunchingAgentId((prev) => (prev === agentId ? null : prev));
    }
  };

  return (
    <div className="monitor-view">
      <div className="monitor-header">
        <div className="monitor-title">
          <span>ClawMux Monitor</span>
          <span className="monitor-status-dot" style={{ background: snap.connected ? '#22c55e' : '#ef4444' }} />
        </div>
        <div className="monitor-summary">
          <span>{counts.active} active</span>
          <span className="monitor-sep">·</span>
          <span>{counts.online} online</span>
          <span className="monitor-sep">·</span>
          <span>{counts.total} total</span>
          <span className="monitor-sep">·</span>
          <span>click agent to tail</span>
        </div>
        <button className="monitor-close" onClick={onClose} title="Close monitor">
          ×
        </button>
      </div>

      <div className="monitor-body">
        <div className={`monitor-table-wrap ${selectedAgentId ? 'has-tail' : ''}`}>
          <table className="monitor-table">
            <thead>
              <tr>
                <th>AGENT</th>
                <th>BACKEND</th>
                <th>MODEL</th>
                <th>THINK</th>
                <th className="monitor-col-num">CTX</th>
                <th>STATUS</th>
                <th>TOOL</th>
                <th>SESSION</th>
                <th className="monitor-col-num">ACTIVITY</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(([id, a]) => {
                const st = statusStyle[a.status] || statusStyle.offline;
                const tool = shortenTool(a.currentTool);
                const sid = a.sessionId ? a.sessionId.slice(0, 16) : '';
                const offline = a.status === 'offline';
                return (
                  <tr
                    key={id}
                    className={`monitor-row ${id === selectedAgentId ? 'active' : ''}`}
                    onClick={() => handleRowClick(id, a)}
                    style={{ opacity: offline ? 0.55 : 1 }}
                  >
                    <td className="monitor-cell-name">{a.name}</td>
                    <td style={{ color: backendColor[a.backend] || 'inherit' }}>{a.backend || '-'}</td>
                    <td className="monitor-cell-dim">{a.model || ''}</td>
                    <td className="monitor-cell-dim">{a.effort || ''}</td>
                    <td className="monitor-col-num" style={{ color: ctxColor(a.contextPercent) }}>
                      {!offline && a.contextPercent != null ? `${a.contextPercent}%` : ''}
                    </td>
                    <td style={{ color: st.color }}>
                      <span className="monitor-icon">{st.icon}</span> {st.label}
                    </td>
                    <td className="monitor-cell-tool">{tool}</td>
                    <td className="monitor-cell-dim monitor-cell-mono">{sid}</td>
                    <td className="monitor-col-num monitor-cell-dim">{!offline ? timeAgo(a.lastActivity) : ''}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {selectedAgentId && (
          <TailPanel
            agentId={selectedAgentId}
            agent={selectedAgent}
            view={tailView}
            onViewChange={setTailView}
            onOpenChat={handleOpenChat}
            launching={launchingAgentId === selectedAgentId}
            launchError={launchErrorAgentId === selectedAgentId ? launchError : ''}
          />
        )}
      </div>

      {(snap.usage.anthropic || snap.usage.openai) && (
        <div className="monitor-usage">
          {snap.usage.anthropic && (
            <div className="monitor-usage-row">
              <span className="monitor-usage-label">Anthropic</span>
              <span className="monitor-usage-segment">
                <span className="monitor-usage-period">5h</span>
                <UsageBar pct={snap.usage.anthropic.fiveHour} />
                <span className="monitor-usage-pct">{snap.usage.anthropic.fiveHour ?? '?'}%</span>
              </span>
              <span className="monitor-usage-segment">
                <span className="monitor-usage-period">7d</span>
                <UsageBar pct={snap.usage.anthropic.weekly} />
                <span className="monitor-usage-pct">{snap.usage.anthropic.weekly ?? '?'}%</span>
              </span>
            </div>
          )}
          {snap.usage.openai && (
            <div className="monitor-usage-row">
              <span className="monitor-usage-label">OpenAI</span>
              <span className="monitor-usage-segment">
                <span className="monitor-usage-period">5h</span>
                <UsageBar pct={snap.usage.openai.fiveHour} />
                <span className="monitor-usage-pct">{snap.usage.openai.fiveHour ?? '?'}%</span>
              </span>
              <span className="monitor-usage-segment">
                <span className="monitor-usage-period">7d</span>
                <UsageBar pct={snap.usage.openai.weekly} />
                <span className="monitor-usage-pct">{snap.usage.openai.weekly ?? '?'}%</span>
              </span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
