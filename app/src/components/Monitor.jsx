import React, { useMemo, useSyncExternalStore } from 'react';
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
 * Subscribes to the shared monitor store. Click an agent row to focus that
 * agent in the chat (and exit monitor).
 */

function UsageBar({ pct, width = 12 }) {
  const filled = pct == null ? 0 : Math.round((pct / 100) * width);
  const color = ctxColor(pct);
  return (
    <span style={{ fontFamily: 'monospace', color }}>
      [{'█'.repeat(filled)}{'░'.repeat(width - filled)}]
    </span>
  );
}

export function Monitor({ onClose }) {
  const snap = useSyncExternalStore(subscribe, getSnapshot);
  // Subscribe to the 1Hz tick so timeAgo() refreshes.
  useSyncExternalStore(subscribeTick, getTick);

  const rows = useMemo(() => {
    return Object.entries(snap.agents)
      .filter(([k]) => k !== '_usage')
      .sort((a, b) => (a[1].name || '').localeCompare(b[1].name || ''));
  }, [snap.agents]);

  const counts = useMemo(() => {
    const all = rows.map(([, a]) => a);
    return {
      total: all.length,
      online: all.filter((a) => a.status !== 'offline').length,
      active: all.filter((a) => a.status !== 'offline' && a.status !== 'idle').length,
    };
  }, [rows]);

  const handleRowClick = (agentId) => {
    switchToAgent(agentId.toLowerCase());
    if (onClose) onClose();
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
        </div>
        <button className="monitor-close" onClick={onClose} title="Close monitor">×</button>
      </div>

      <div className="monitor-table-wrap">
        <table className="monitor-table">
          <thead>
            <tr>
              <th>AGENT</th>
              <th>BACKEND</th>
              <th>MODEL</th>
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
                  className="monitor-row"
                  onClick={() => handleRowClick(id)}
                  style={{ opacity: offline ? 0.55 : 1 }}
                >
                  <td className="monitor-cell-name">{a.name}</td>
                  <td style={{ color: backendColor[a.backend] || 'inherit' }}>{a.backend || '-'}</td>
                  <td className="monitor-cell-dim">{a.model || ''}</td>
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
