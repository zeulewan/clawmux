import React, { useState, useEffect, useSyncExternalStore } from 'react';
import { subscribe, getCurrentAgent } from '../state/sessions.js';

const AGENTS = [
  { id: 'af_sky', name: 'Sky' },
  { id: 'am_adam', name: 'Adam' },
  { id: 'am_echo', name: 'Echo' },
  { id: 'am_eric', name: 'Eric' },
  { id: 'bm_fable', name: 'Fable' },
  { id: 'af_nova', name: 'Nova' },
  { id: 'am_onyx', name: 'Onyx' },
  { id: 'af_sarah', name: 'Sarah' },
  { id: 'af_alloy', name: 'Alloy' },
  { id: 'af_bella', name: 'Bella' },
  { id: 'bm_daniel', name: 'Daniel' },
  { id: 'bf_emma', name: 'Emma' },
  { id: 'am_fenrir', name: 'Fenrir' },
  { id: 'bm_george', name: 'George' },
  { id: 'af_heart', name: 'Heart' },
  { id: 'af_jessica', name: 'Jessica' },
  { id: 'af_kore', name: 'Kore' },
  { id: 'am_liam', name: 'Liam' },
  { id: 'bf_alice', name: 'Alice' },
  { id: 'af_aoede', name: 'Aoede' },
  { id: 'af_jadzia', name: 'Jadzia' },
  { id: 'bm_lewis', name: 'Lewis' },
  { id: 'bf_lily', name: 'Lily' },
  { id: 'am_michael', name: 'Michael' },
  { id: 'af_nicole', name: 'Nicole' },
  { id: 'am_puck', name: 'Puck' },
  { id: 'af_river', name: 'River' },
];

/**
 * StatusBar — shows agent name + context %, 5h usage, 7d usage in the top right.
 */
export function StatusBar() {
  const [usage, setUsage] = useState({});
  const currentAgent = useSyncExternalStore(subscribe, getCurrentAgent);

  useEffect(() => {
    // Fetch initial usage from API
    fetch('/api/usage')
      .then((r) => r.json())
      .then((d) => {
        if (d && !d.error) setUsage((prev) => ({ ...prev, ...d }));
      })
      .catch(() => {});

    // Also listen for live updates
    const handler = (event) => {
      if (event.data?.type !== 'from-extension') return;
      const msg = event.data.message;
      if (msg?.type === 'request' && msg?.request?.type === 'usage_update') {
        setUsage((prev) => ({ ...prev, ...msg.request.utilization }));
      }
    };
    window.addEventListener('message', handler);
    return () => window.removeEventListener('message', handler);
  }, []);

  const ctx = usage.contextPercent;
  const fiveH = usage.fiveHour;
  const weekly = usage.weekly;

  // Show 5h as percentage (Codex) or status (Claude)
  const fiveHText =
    fiveH?.percent != null
      ? `${fiveH.percent}%`
      : fiveH?.status === 'allowed'
        ? 'OK'
        : fiveH?.status === 'rejected'
          ? 'LIMIT'
          : null;
  const fiveHWarn = fiveH?.percent > 80 || fiveH?.status === 'rejected';
  const weeklyText = weekly?.percent != null ? `${weekly.percent}%` : null;
  const weeklyWarn = weekly?.percent > 80;

  const agentName = currentAgent ? AGENTS.find((a) => a.id === currentAgent)?.name || currentAgent : null;

  if (ctx == null && !fiveHText && !weeklyText && !agentName) return null;

  return (
    <div className="status-bar">
      {agentName && <span className="status-agent-name">{agentName}</span>}
      {ctx != null && (
        <span className="status-item" title="Context window usage">
          <span className="status-label">CTX</span>
          <span className={`status-value ${ctx > 80 ? 'status-warn' : ''}`}>{ctx}%</span>
        </span>
      )}
      {fiveHText && (
        <span className="status-item" title="5-hour rate limit">
          <span className="status-label">5h</span>
          <span className={`status-value ${fiveHWarn ? 'status-warn' : ''}`}>{fiveHText}</span>
        </span>
      )}
      {weeklyText && (
        <span className="status-item" title="7-day rate limit">
          <span className="status-label">7d</span>
          <span className={`status-value ${weeklyWarn ? 'status-warn' : ''}`}>{weeklyText}</span>
        </span>
      )}
    </div>
  );
}
