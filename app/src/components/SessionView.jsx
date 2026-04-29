import React, { useState, useEffect, useSyncExternalStore } from 'react';
import { ChatContainer } from './ChatContainer.jsx';
import {
  subscribe,
  getActiveSession,
  getCurrentAgent,
  getCurrentProvider,
  getCurrentModel,
} from '../state/sessions.js';
import { isConnected, onMessage } from '../lib/ws.js';
import { subscribe as subscribeMonitor, getSnapshot as getMonitorSnapshot, ctxColor } from '../state/monitor.js';
import { subscribe as subscribeVoice, getSnapshot as getVoiceSnapshot, setVoiceEnabled } from '../state/voice.js';

const AGENT_NAMES = {
  af_sky: 'Sky',
  am_adam: 'Adam',
  am_echo: 'Echo',
  am_eric: 'Eric',
  bm_fable: 'Fable',
  af_nova: 'Nova',
  am_onyx: 'Onyx',
  af_sarah: 'Sarah',
  af_alloy: 'Alloy',
  af_bella: 'Bella',
  bm_daniel: 'Daniel',
  bf_emma: 'Emma',
  am_fenrir: 'Fenrir',
  bm_george: 'George',
  af_heart: 'Heart',
  af_jessica: 'Jessica',
  af_kore: 'Kore',
  am_liam: 'Liam',
  bf_alice: 'Alice',
  af_aoede: 'Aoede',
  af_jadzia: 'Jadzia',
  bm_lewis: 'Lewis',
  bf_lily: 'Lily',
  am_michael: 'Michael',
  af_nicole: 'Nicole',
  am_puck: 'Puck',
  af_river: 'River',
};

/**
 * SessionView — main chat layout.
 * Structure: cmx-root > cmx-header + cmx-body > cmx-content > sessionBody > chatContainer
 */
export function SessionView() {
  const activeSession = useSyncExternalStore(subscribe, getActiveSession);
  const currentAgent = useSyncExternalStore(subscribe, getCurrentAgent);
  const currentModel = useSyncExternalStore(subscribe, getCurrentModel);
  const currentProvider = useSyncExternalStore(subscribe, getCurrentProvider);
  const [usage, setUsage] = useState({});
  const [connected, setConnected] = useState(isConnected());
  const monitor = useSyncExternalStore(subscribeMonitor, getMonitorSnapshot);
  const voice = useSyncExternalStore(subscribeVoice, getVoiceSnapshot);

  // Resolve live ctx for the focused agent from the monitor store. This is the
  // source of truth — keeps the header CTX always in sync with what the monitor
  // shows, even before the per-session usage_update message arrives.
  const monitorAgent = currentAgent
    ? monitor.agents[currentAgent] || Object.values(monitor.agents).find((a) => a?.name?.toLowerCase() === currentAgent)
    : null;
  const liveCtx = monitorAgent?.contextPercent;
  const ctxValue = liveCtx != null ? liveCtx : usage.contextPercent;
  const liveEffort = monitorAgent?.effort || activeSession?.effortLevel || null;

  // Per-backend rate limits. The 5h/7d quotas only apply to claude and codex;
  // pi/opencode have no rate-limit telemetry to show.
  const providerToUsageKey = { claude: 'anthropic', codex: 'openai' };
  const usageKey = providerToUsageKey[currentProvider];
  const backendUsage = usageKey ? monitor.usage?.[usageKey] : null;
  const fiveHour = backendUsage?.fiveHour;
  const weekly = backendUsage?.weekly;

  useEffect(() => {
    const unsub = onMessage((msg) => {
      if (msg.type === 'ws_reconnected') setConnected(true);
      if (msg.type === 'ws_disconnected') setConnected(false);
    });
    return unsub;
  }, []);

  // Clear stale busy indicator: if the server reports idle/offline but the
  // client session is still busy, the result event was lost. Reset it.
  useEffect(() => {
    const serverStatus = monitorAgent?.status;
    if (activeSession?.busy && (serverStatus === 'idle' || serverStatus === 'offline')) {
      activeSession.busy = false;
      activeSession._currentAssistantMessage = null;
      activeSession.notify();
    }
  }, [monitorAgent?.status, activeSession]);

  useEffect(() => {
    fetch('/api/usage')
      .then((r) => r.json())
      .then((d) => {
        if (d && !d.error) setUsage((prev) => ({ ...prev, ...d }));
      })
      .catch(() => {});
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

  return (
    <div style={{ display: 'flex', flex: 1, maxWidth: '100%', minHeight: 0, overflow: 'hidden' }}>
      <div className="cmx-root ">
        {/* Header */}
        <div className="cmx-header">
          <div className="titleGroup">
            <span
              className="connection-indicator"
              title={connected ? 'Connected' : 'Disconnected — reconnecting...'}
              style={{
                display: 'inline-block',
                width: 8,
                height: 8,
                borderRadius: '50%',
                backgroundColor: connected ? '#4caf50' : '#f44336',
                marginRight: 8,
                transition: 'background-color 0.3s',
              }}
            />
            {!connected && <span style={{ fontSize: 12, color: '#f44336', fontWeight: 500 }}>Reconnecting...</span>}
          </div>
          <div className="header-stats header-stats-left">
            {currentAgent && <span className="header-agent-name">{AGENT_NAMES[currentAgent] || currentAgent}</span>}
            <span className="header-stat" title="Context window usage">
              <span className="header-stat-label">CTX</span>
              <span style={{ color: ctxValue != null ? ctxColor(ctxValue) : undefined }}>
                {ctxValue != null ? `${ctxValue}%` : '—'}
              </span>
            </span>
            <span className="header-stat" title="Thinking / effort level">
              <span className="header-stat-label">THINK</span>
              <span>{liveEffort || '—'}</span>
            </span>
          </div>
          <div className="headerSpacer" />
          {/* Voice mode toggle */}
          <button
            className={`voiceToggle ${voice.enabled ? 'voiceToggleActive' : ''}`}
            title={voice.enabled ? 'Voice mode on — click to disable' : 'Enable voice mode'}
            onClick={() => setVoiceEnabled(!voice.enabled)}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12 14c1.66 0 3-1.34 3-3V5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm-1-9c0-.55.45-1 1-1s1 .45 1 1v6c0 .55-.45 1-1 1s-1-.45-1-1V5zm6 6c0 2.76-2.24 5-5 5s-5-2.24-5-5H5c0 3.53 2.61 6.43 6 6.92V21h2v-3.08c3.39-.49 6-3.39 6-6.92h-2z" />
            </svg>
            {voice.speakingMsgId && <span className="voiceToggleDot" />}
          </button>
          <div className="header-stats">
            <span className="header-stat" title="Backend / Model">
              <span className="header-stat-label">{currentProvider}</span>
              <span>{currentModel}</span>
            </span>
            {fiveHour != null && (
              <span className="header-stat" title={`${usageKey} 5-hour rate limit`}>
                <span className="header-stat-label">5h</span>
                <span className={fiveHour > 80 ? 'header-stat-warn' : ''}>{fiveHour}%</span>
              </span>
            )}
            {weekly != null && (
              <span className="header-stat" title={`${usageKey} 7-day rate limit`}>
                <span className="header-stat-label">7d</span>
                <span className={weekly > 80 ? 'header-stat-warn' : ''}>{weekly}%</span>
              </span>
            )}
          </div>
        </div>

        {/* Body */}
        <div className="cmx-body">
          <div className="cmx-content">
            <div className="sessionBody">
              {activeSession ? (
                <ChatContainer
                  key={activeSession?.conversationId || activeSession?.sessionId || activeSession?.channelId}
                  session={activeSession}
                  effortLevel={liveEffort || undefined}
                />
              ) : (
                <div className="chatContainer">
                  <div className="emptyState">
                    <div className="emptyStateContent">
                      <div className="emptyStateText">What can I help you with?</div>
                    </div>
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
