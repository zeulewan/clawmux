// ClawMux — Sidebar Module
// Extracted from hub.html Phase 3 refactor.
// All functions and variables remain global (window-scoped).
//
// Dependencies (defined in state.js and hub.html inline script):
//   state.js: sessions, activeSessionId, spawningVoices, recording,
//             pendingListenSessionId
//   audio.js: stopActiveAudio, stopRecording, stopElapsedTimer,
//             stopThinkingSound, setSessionState, getSessionState
//   hub.html: chatArea, controls, statusEl, dot, connLabel, inputMode,
//             currentProject, currentProjectVoices, allProjects, textInputBar,
//             switchTab, spawnSession, showContextMenu, hideDebugPanel,
//             debugActive

// --- Voice display names ---
const VOICE_NAMES = {
  // Project 1 (default)
  af_sky: 'Sky', af_alloy: 'Alloy', af_sarah: 'Sarah',
  am_adam: 'Adam', am_echo: 'Echo', am_onyx: 'Onyx',
  bm_fable: 'Fable', af_nova: 'Nova', am_eric: 'Eric',
  // Project 2
  af_bella: 'Bella', af_jessica: 'Jessica', af_heart: 'Heart',
  am_michael: 'Michael', am_liam: 'Liam', am_fenrir: 'Fenrir',
  bf_emma: 'Emma', bm_george: 'George', bm_daniel: 'Daniel',
  // Project 3
  af_aoede: 'Aoede', af_jadzia: 'Jadzia', af_kore: 'Kore',
  af_nicole: 'Nicole', af_river: 'River', am_puck: 'Puck',
  bf_alice: 'Alice', bf_lily: 'Lily', bm_lewis: 'Lewis',
};
const VOICE_COLORS = {
  // Project 1
  af_sky: '#3A86FF', af_alloy: '#E67E22', af_sarah: '#E63946',
  am_adam: '#2ECC71', am_echo: '#9B59B6', am_onyx: '#7F8C8D',
  bm_fable: '#F1C40F', af_nova: '#FF6B9D', am_eric: '#00B4D8',
  // Project 2
  af_bella: '#FF7043', af_jessica: '#AB47BC', af_heart: '#EC407A',
  am_michael: '#26A69A', am_liam: '#5C6BC0', am_fenrir: '#78909C',
  bf_emma: '#FFA726', bm_george: '#66BB6A', bm_daniel: '#42A5F5',
  // Project 3
  af_aoede: '#CE93D8', af_jadzia: '#4DD0E1', af_kore: '#A1887F',
  af_nicole: '#F48FB1', af_river: '#80CBC4', am_puck: '#FFD54F',
  bf_alice: '#90CAF9', bf_lily: '#C5E1A5', bm_lewis: '#BCAAA4',
};
const VOICE_ICONS = {
  af_sky: '<svg viewBox="0 0 24 16" fill="currentColor" style="width:1.2em;height:0.8em"><path d="M19.35 8.04A7.49 7.49 0 0 0 12 2C9.11 2 6.6 3.64 5.35 6.04A5.994 5.994 0 0 0 0 12c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96z"/></svg>',
  af_alloy: '\u2666\uFE0E',
  af_sarah: '\u2665\uFE0E',
  am_adam: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M17 8C8 10 5.9 16.17 3.82 21.34l1.89.66.95-2.3c.48.17.98.3 1.34.3C19 20 22 3 22 3c-1 2-8 2.25-13 3.25S2 11.5 2 13.5s1.75 3.75 1.75 3.75C7 8 17 8 17 8z"/></svg>',
  am_echo: '<svg viewBox="0 0 22 20" fill="currentColor" style="width:1em;height:0.9em"><rect x="0" y="7" width="2.4" height="6" rx="1.2"/><rect x="4.9" y="3" width="2.4" height="14" rx="1.2"/><rect x="9.8" y="0" width="2.4" height="20" rx="1.2"/><rect x="14.7" y="4" width="2.4" height="12" rx="1.2"/><rect x="19.6" y="6" width="2.4" height="8" rx="1.2"/></svg>',
  am_onyx: '<svg viewBox="0 0 18 22" fill="currentColor" style="width:0.85em;height:1em"><path d="M9 0L0 4v6c0 5.5 3.8 10.7 9 12 5.2-1.3 9-6.5 9-12V4L9 0z"/></svg>',
  bm_fable: '<svg viewBox="0 0 20 18" fill="currentColor" style="width:1em;height:0.9em"><path d="M1 1.5C1 .67 1.67 0 2.5 0H8c1.1 0 2 .9 2 2v14l-.5-.3c-.3-.2-.7-.2-1 0L7 16.8l-1.5-1.1c-.3-.2-.7-.2-1 0L3 16.8l-1.5-1.1c-.2-.15-.5-.15-.5.3V1.5zM12 2c0-1.1.9-2 2-2h5.5c.83 0 1.5.67 1.5 1.5V16c0-.45-.3-.45-.5-.3L19 16.8l-1.5-1.1c-.3-.2-.7-.2-1 0L15 16.8l-1.5-1.1c-.3-.2-.7-.2-1 0l-.5.3V2z"/></svg>',
  af_nova: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 2L9.19 8.63 2 9.24l5.46 4.73L5.82 21 12 17.27 18.18 21l-1.64-7.03L22 9.24l-7.19-.61z"/></svg>',
  am_eric: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M3.5 18.49l6-6.01 4 4L22 6.92l-1.41-1.41-7.09 7.97-4-4L2 16.99z"/></svg>',
  // Project 2
  af_bella: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 3c-4.97 0-9 4.03-9 9s4.03 9 9 9 9-4.03 9-9-4.03-9-9-9zm0 16c-3.86 0-7-3.14-7-7s3.14-7 7-7 7 3.14 7 7-3.14 7-7 7zm-1-11h2v6h-2zm0 8h2v2h-2z"/></svg>',
  af_jessica: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"/></svg>',
  af_heart: '\u2764\uFE0E',
  am_michael: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg>',
  am_liam: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z"/></svg>',
  am_fenrir: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L10 14v1c0 1.1.9 2 2 2v3.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>',
  bf_emma: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M20 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.9-2-2-2zm0 4l-8 5-8-5V6l8 5 8-5v2z"/></svg>',
  bm_george: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-5 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>',
  bm_daniel: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"/></svg>',
  // Project 3
  af_aoede: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 3v9.28c-.47-.17-.97-.28-1.5-.28C8.01 12 6 14.01 6 16.5S8.01 21 10.5 21c2.31 0 4.2-1.75 4.45-4H15V6h4V3h-7z"/></svg>',
  af_jadzia: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M20.5 6c-2.61.7-5.67 1-8.5 1s-5.89-.3-8.5-1L3 8c1.86.5 4 .83 6 1v13h2v-6h2v6h2V9c2-.17 4.14-.5 6-1l-.5-2zM12 6c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2z"/></svg>',
  af_kore: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M6.05 8.05a7.001 7.001 0 0 0 0 9.9C7.42 19.32 9.21 20 12 20s4.58-.68 5.95-2.05a7.001 7.001 0 0 0 0-9.9C16.58 6.68 14.79 6 12 6s-4.58.68-5.95 2.05zM12 2C4 2 2 6 2 12s2 10 10 10 10-4 10-10S20 2 12 2z"/></svg>',
  af_nicole: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>',
  af_river: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M1 18q4-3 6.5-3t4.5 3q2 3 4.5 3t6.5-3v2q-4 3-6.5 3T12 17q-2-3-4.5-3T1 17v-2zM1 14q4-3 6.5-3t4.5 3q2 3 4.5 3t6.5-3v2q-4 3-6.5 3T12 13q-2-3-4.5-3T1 13v-2zM1 10q4-3 6.5-3t4.5 3q2 3 4.5 3t6.5-3v2q-4 3-6.5 3T12 9Q10 6 7.5 6T1 9V7z"/></svg>',
  am_puck: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM8.5 8c.83 0 1.5.67 1.5 1.5S9.33 11 8.5 11 7 10.33 7 9.5 7.67 8 8.5 8zM12 18c-2.28 0-4.22-1.66-5-4h10c-.78 2.34-2.72 4-5 4zm3.5-7c-.83 0-1.5-.67-1.5-1.5S14.67 8 15.5 8s1.5.67 1.5 1.5-.67 1.5-1.5 1.5z"/></svg>',
  bf_alice: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M18 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zM6 4h5v8l-2.5-1.5L6 12V4z"/></svg>',
  bf_lily: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M12 22c4.97 0 9-4.03 9-9-4.97 0-9 4.03-9 9zM5.6 10.25c0 1.38 1.12 2.5 2.5 2.5.53 0 1.01-.16 1.42-.44l-.02.19c0 1.38 1.12 2.5 2.5 2.5s2.5-1.12 2.5-2.5l-.02-.19c.4.28.89.44 1.42.44 1.38 0 2.5-1.12 2.5-2.5 0-1-.59-1.85-1.43-2.25.84-.4 1.43-1.25 1.43-2.25 0-1.38-1.12-2.5-2.5-2.5-.53 0-1.01.16-1.42.44l.02-.19C14.5 2.12 13.38 1 12 1S9.5 2.12 9.5 3.5l.02.19c-.4-.28-.89-.44-1.42-.44-1.38 0-2.5 1.12-2.5 2.5 0 1 .59 1.85 1.43 2.25-.84.4-1.43 1.25-1.43 2.25zM12 5.5c1.38 0 2.5 1.12 2.5 2.5s-1.12 2.5-2.5 2.5S9.5 9.38 9.5 8s1.12-2.5 2.5-2.5zM3 13c0 4.97 4.03 9 9 9-4.97 0-9-4.03-9-9z"/></svg>',
  bm_lewis: '<svg viewBox="0 0 24 24" fill="currentColor" style="width:1em;height:1em"><path d="M19 3h-4.18C14.4 1.84 13.3 1 12 1c-1.3 0-2.4.84-2.82 2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 0c.55 0 1 .45 1 1s-.45 1-1 1-1-.45-1-1 .45-1 1-1zm2 14H7v-2h7v2zm3-4H7v-2h10v2zm0-4H7V7h10v2z"/></svg>',
};
function voiceDisplayName(v) { return VOICE_NAMES[v] || v; }
function voiceColor(v) { return VOICE_COLORS[v] || '#4a90ff'; }
function voiceIcon(v) { return VOICE_ICONS[v] || '\u{1F3A4}'; }
function hexToRgba(hex, alpha) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgba(${r},${g},${b},${alpha})`;
}


// --- Helpers ---
function setConnected(state) {
  dot.classList.remove('connected', 'connecting');
  if (state === 'connected') {
    dot.classList.add('connected');
    connLabel.textContent = 'Live';
  } else if (state === 'connecting') {
    dot.classList.add('connecting');
    connLabel.textContent = 'Connecting...';
  } else {
    connLabel.textContent = 'Offline';
  }
}

function setStatus(text, sessionId) {
  if (statusEl.textContent !== text) {
    statusEl.style.opacity = '0';
    requestAnimationFrame(() => {
      statusEl.textContent = text;
      requestAnimationFrame(() => { statusEl.style.opacity = ''; });
    });
  }
  // Update session statusText so voice grid stays in sync
  const sid = sessionId || activeSessionId;
  if (sid) {
    const s = sessions.get(sid);
    if (s) {
      s.statusText = text;
      // Sidebar reflects server state only — speaking indicator not shown on sidebar
    }
  }
  renderSidebar();
}

function updateHeaderProjectStatus() {
  const el = document.getElementById('header-project-status');
  if (!el) return;
  if (activeSessionId) {
    const s = sessions.get(activeSessionId);
    if (s && s.project) {
      el.innerHTML = '<div style="font-weight:600;color:var(--text-secondary);">' + s.project + '</div>' +
        (s.project_repo ? '<div style="opacity:0.7;">' + s.project_repo + '</div>' : '');
      return;
    }
  }
  el.innerHTML = '';
}

function updateLayout() {
  renderSidebar(); // scroll preservation is handled inside renderSidebar
  if (debugActive) return; // debug panel handles its own layout
  const inAgentChat = !!(activeSessionId && sessions.has(activeSessionId));
  const inGroupChat = !!(typeof activeGroupId !== 'undefined' && activeGroupId);
  const inChat = inAgentChat || inGroupChat;
  document.getElementById('welcome-view').style.display = (!inChat && !focusMode) ? 'flex' : 'none';
  document.getElementById('focus-view').style.display = focusMode ? 'flex' : 'none';
  chatArea.style.display = inChat ? 'flex' : 'none';
  document.getElementById('debug-panel').style.display = 'none';
  // Settings uses class-based visibility — don't touch display here
  // Both agent chats and group chats respect inputMode for input controls
  if (inChat) {
    if (typeof inputMode !== 'undefined' && inputMode === 'typing') {
      controls.style.display = 'none';
      textInputBar.classList.add('active');
      document.documentElement.style.setProperty('--chat-bottom-pad', '90px');
    } else {
      controls.style.display = 'grid';
      textInputBar.classList.remove('active');
      document.documentElement.style.setProperty('--chat-bottom-pad', '200px');
    }
  } else {
    controls.style.display = 'none';
    textInputBar.classList.remove('active');
  }
  if (typeof window._updateScrollBtnPos === 'function') window._updateScrollBtnPos();
}

// --- Welcome view (no chat selected) ---
function showWelcome() {
  stopThinkingSound();
  if (recording) stopRecording(false); // send recording before switching
  stopActiveAudio();
  stopElapsedTimer();
  pendingListenSessionId = null;
  activeSessionId = null;
  if (typeof activeGroupId !== 'undefined') activeGroupId = null;
  hideDebugPanel();
  exitFocusMode();
  document.getElementById('active-voice').style.display = 'none';
  document.getElementById('session-model').style.display = 'none';
  document.getElementById('main-content').style.backgroundColor = '';
  textInputBar.classList.remove('active');
  updateLayout();
}
// Alias for compatibility
function showVoiceGrid() { showWelcome(); }

let focusMode = false;

function switchToFocus() {
  stopThinkingSound();
  if (recording) stopRecording(false);
  stopActiveAudio();
  stopElapsedTimer();
  pendingListenSessionId = null;
  activeSessionId = null;
  hideDebugPanel();
  focusMode = true;
  document.getElementById('active-voice').style.display = 'none';
  document.getElementById('session-model').style.display = 'none';
  document.getElementById('main-content').style.backgroundColor = '';
  textInputBar.classList.remove('active');
  document.getElementById('focus-card').classList.add('selected');
  document.getElementById('welcome-view').style.display = 'none';
  document.getElementById('focus-view').style.display = 'flex';
  updateLayout();
}

function exitFocusMode() {
  focusMode = false;
  document.getElementById('focus-card').classList.remove('selected');
  document.getElementById('focus-view').style.display = 'none';
}

// --- Sidebar rendering ---
function toggleSidebarVisibility() {
  document.body.classList.toggle('sidebar-hidden');
  // On mobile, also collapse the expanded overlay if open
  const sidebar = document.getElementById('sidebar');
  if (sidebar && sidebar.classList.contains('expanded')) {
    sidebar.classList.remove('expanded');
    const overlay = document.getElementById('sidebar-overlay');
    if (overlay) overlay.classList.remove('visible');
  }
  localStorage.setItem('sidebar_hidden', document.body.classList.contains('sidebar-hidden') ? '1' : '');
}

function toggleSidebarExpand() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  const chat = document.getElementById('chat-area');
  const scrollPos = chat ? chat.scrollTop : 0;
  if (sidebar.classList.contains('expanded')) {
    collapseSidebar();
  } else {
    sidebar.classList.add('expanded');
    overlay.classList.add('visible');
    renderSidebar();
  }
  // Restore scroll position after layout change
  requestAnimationFrame(() => { if (chat) chat.scrollTop = scrollPos; });
}
function collapseSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  sidebar.classList.remove('expanded');
  overlay.classList.remove('visible');
  // Scroll chat to bottom after layout settles
  const chat = document.getElementById('chat-area');
  if (chat) {
    chat.scrollTop = chat.scrollHeight;
    requestAnimationFrame(() => { chat.scrollTop = chat.scrollHeight; });
    setTimeout(() => { chat.scrollTop = chat.scrollHeight; }, 20);
  }
}

// --- Centralized session state machine ---
// Valid states: 'idle', 'processing', 'compacting', 'starting', 'offline' (server state only — no speaking/listening)
function setSessionSidebarState(sessionId, newState) {
  const s = sessions.get(sessionId);
  if (!s) return;
  const prev = s.sidebarState || 'idle';
  if (prev === newState) return;
  s.sidebarState = newState;
  renderSidebar();
  // Update chat input stop button for active session
  if (sessionId === activeSessionId) updateChatStopButton();
}

function updateChatStopButton() {
  const hasSession = !!(activeSessionId && sessions.has(activeSessionId));
  const textBtn = document.getElementById('text-stop');
  const voiceBtn = document.getElementById('voice-stop');
  if (textBtn) hasSession ? textBtn.classList.add('btn-visible') : textBtn.classList.remove('btn-visible');
  if (voiceBtn) hasSession ? voiceBtn.classList.add('btn-visible') : voiceBtn.classList.remove('btn-visible');
}

let _interruptDebounce = false;
function interruptActiveAgent() {
  if (!activeSessionId || _interruptDebounce) return;
  _interruptDebounce = true;
  fetch(`/api/sessions/${activeSessionId}/interrupt`, { method: 'POST' }).catch(e => console.warn('interrupt:', e));
  // Disable for 2s to prevent double-tap (double Escape triggers exit prompt)
  const btns = document.querySelectorAll('#text-stop, #voice-stop');
  btns.forEach(b => { b.disabled = true; b.style.opacity = '0.3'; });
  setTimeout(() => {
    _interruptDebounce = false;
    btns.forEach(b => { b.disabled = false; b.style.opacity = ''; });
  }, 2000);
}

function markSessionUnread(sessionId) {
  const s = sessions.get(sessionId);
  if (!s || sessionId === activeSessionId) return;
  s.unreadCount = (s.unreadCount || 0) + 1;
  renderSidebar();
}

function clearSessionUnread(sessionId) {
  const s = sessions.get(sessionId);
  if (!s) return;
  if (s.unreadCount === 0) return;
  s.unreadCount = 0;
  // Persist to server
  fetch(`/api/sessions/${sessionId}/mark-read`, { method: 'POST' }).catch(e => console.warn('mark-read:', e));
  renderSidebar();
}

function _sidebarState(voiceId) {
  let session = null;
  for (const [sid, s] of sessions) {
    if (s.voice === voiceId) { session = s; break; }
  }
  const isSpawning = spawningVoices.has(voiceId);
  const hasUnread = session && (session.unreadCount || 0) > 0;
  let stateClass = 'offline', statusLabel = 'Offline';
  if (isSpawning) {
    stateClass = 'starting'; statusLabel = 'Starting...';
  } else if (session) {
    // Use centralized sidebarState as primary source of truth
    const st = session.sidebarState || 'idle';
    if (st === 'starting') {
      stateClass = 'starting'; statusLabel = 'Starting...';
    } else if (session.compacting) {
      stateClass = 'working'; statusLabel = session.toolStatusText || 'Compacting';
    } else if (st === 'processing') {
      stateClass = 'working';
      statusLabel = session.toolStatusText || session.toolName || 'Processing';
    } else if (st === 'speaking' || st === 'listening') {
      // Speaking/listening are browser-only — sidebar shows idle
      stateClass = 'idle'; statusLabel = 'Idle';
    } else {
      // idle
      stateClass = 'idle'; statusLabel = 'Idle';
    }
  }
  const isSelected = session && session.session_id === activeSessionId;
  const projectText = session && session.project
    ? session.project
    : '';
  const projectArea = session && session.project_repo ? session.project_repo : '';
  const roleText = session && session.role ? session.role : '';
  const taskText = session && session.task ? session.task : '';
  const isCompacting = session && session.compacting;
  return { session, isSpawning, stateClass, statusLabel, isSelected, projectText, projectArea, roleText, taskText, hasUnread, isCompacting };
}

function _updateSidebarCard(card, voiceId, state) {
  const { session, isSpawning, stateClass, statusLabel, isSelected, projectText, projectArea, roleText, taskText, hasUnread, isCompacting } = state;
  // Update state class only if changed
  const stateClasses = ['starting', 'working', 'unread', 'idle', 'offline'];
  const curState = stateClasses.find(c => card.classList.contains(c)) || '';
  if (curState !== stateClass) {
    stateClasses.forEach(c => card.classList.remove(c));
    if (stateClass) card.classList.add(stateClass);
  }
  card.classList.toggle('selected', !!isSelected);
  // Update status label
  const label = card.querySelector('.sb-status span:not(.sb-dot)');
  if (label && label.textContent !== statusLabel) label.textContent = statusLabel;
  // Update project area line (also purge legacy .sb-area elements)
  card.querySelector('.sb-area')?.remove();
  let areaEl = card.querySelector('.sb-repo');
  if (projectArea) {
    if (!areaEl) {
      areaEl = document.createElement('div');
      areaEl.className = 'sb-repo';
      const info = card.querySelector('.sb-info');
      const nameEl = card.querySelector('.sb-name');
      if (nameEl && nameEl.nextSibling) info.insertBefore(areaEl, nameEl.nextSibling);
      else info.appendChild(areaEl);
    }
    if (areaEl.textContent !== projectArea) areaEl.textContent = projectArea;
  } else if (areaEl) {
    areaEl.remove();
  }
  // Update role line
  let roleEl = card.querySelector('.sb-role');
  if (roleText) {
    if (!roleEl) {
      roleEl = document.createElement('div');
      roleEl.className = 'sb-role';
      const info = card.querySelector('.sb-info');
      const nameEl = card.querySelector('.sb-name');
      if (nameEl && nameEl.nextSibling) info.insertBefore(roleEl, nameEl.nextSibling);
      else info.appendChild(roleEl);
    }
    if (roleEl.textContent !== roleText) roleEl.textContent = roleText;
  } else if (roleEl) {
    roleEl.remove();
  }
  // Update task line
  let taskEl = card.querySelector('.sb-task');
  if (taskText) {
    if (!taskEl) {
      taskEl = document.createElement('div');
      taskEl.className = 'sb-task';
      const info = card.querySelector('.sb-info');
      const statusLine = card.querySelector('.sb-status');
      info.insertBefore(taskEl, statusLine);
    }
    if (taskEl.textContent !== taskText) taskEl.textContent = taskText;
  } else if (taskEl) {
    taskEl.remove();
  }
  // Update unread badge
  let badge = card.querySelector('.sb-unread');
  if (hasUnread && !badge) {
    badge = document.createElement('span');
    badge.className = 'sb-unread';
    card.appendChild(badge);
  } else if (!hasUnread && badge) {
    badge.remove();
  }
  // Update compaction indicator
  let compactEl = card.querySelector('.sb-compacting');
  if (isCompacting && !compactEl) {
    compactEl = document.createElement('div');
    compactEl.className = 'sb-compacting';
    compactEl.textContent = 'Compacting…';
    const info = card.querySelector('.sb-info');
    const statusLine = card.querySelector('.sb-status');
    info.insertBefore(compactEl, statusLine);
  } else if (!isCompacting && compactEl) {
    compactEl.remove();
  }
  // Update closure refs
  card._voiceSession = session;
  card._voiceSpawning = isSpawning;
}

// --- Collapsed state persistence ---
const _collapsedProjects = new Set(JSON.parse(localStorage.getItem('sidebar_collapsed_projects') || '[]'));
function _saveCollapsedState() {
  localStorage.setItem('sidebar_collapsed_projects', JSON.stringify([..._collapsedProjects]));
}

function _toggleProjectCollapse(slug) {
  if (_collapsedProjects.has(slug)) {
    _collapsedProjects.delete(slug);
  } else {
    _collapsedProjects.add(slug);
  }
  _saveCollapsedState();
  renderSidebar();
}

// --- Project group reordering via drag-and-drop ---
let _draggingProjectSlug = null;

// --- Touch drag-and-drop state ---
let _touchDrag = null; // { voiceId, ghost }

function _touchDragStart(voiceId, touch) {
  // Clean up any leaked ghost from a previous drag
  document.querySelectorAll('.touch-drag-ghost').forEach(el => el.remove());
  const ghost = document.createElement('div');
  ghost.className = 'sidebar-card touch-drag-ghost';
  ghost.style.cssText = `position:fixed;left:${touch.clientX - 60}px;top:${touch.clientY - 20}px;` +
    `width:120px;opacity:0.75;pointer-events:none;z-index:9999;` +
    `background:var(--bg2,#222);border-radius:8px;padding:6px 10px;` +
    `font-size:0.8rem;color:var(--text-primary,#eee);box-shadow:0 4px 20px rgba(0,0,0,0.5);`;
  const name = voiceId.replace(/^[ab][mf]_/, '');
  ghost.textContent = name.charAt(0).toUpperCase() + name.slice(1);
  document.body.appendChild(ghost);
  _touchDrag = { voiceId, ghost };
}

function _touchDragMove(touch) {
  if (!_touchDrag) return;
  _touchDrag.ghost.style.left = (touch.clientX - 60) + 'px';
  _touchDrag.ghost.style.top = (touch.clientY - 20) + 'px';
  document.querySelectorAll('.drag-above,.drag-below,.drag-over-group').forEach(el =>
    el.classList.remove('drag-above', 'drag-below', 'drag-over-group'));
  _touchDrag.ghost.style.display = 'none';
  const el = document.elementFromPoint(touch.clientX, touch.clientY);
  _touchDrag.ghost.style.display = '';
  if (!el) return;
  const card = el.closest('.sidebar-card');
  const group = el.closest('.sidebar-project-group');
  if (card && card.dataset.voiceId && card.dataset.voiceId !== _touchDrag.voiceId) {
    const rect = card.getBoundingClientRect();
    card.classList.toggle('drag-above', touch.clientY < rect.top + rect.height / 2);
    card.classList.toggle('drag-below', touch.clientY >= rect.top + rect.height / 2);
  } else if (group) {
    group.classList.add('drag-over-group');
  }
}

function _touchDragEnd(touch) {
  if (!_touchDrag) return;
  const fromVoice = _touchDrag.voiceId;
  _touchDrag.ghost.remove();
  _touchDrag = null;
  document.querySelectorAll('.drag-above,.drag-below,.drag-over-group').forEach(el =>
    el.classList.remove('drag-above', 'drag-below', 'drag-over-group'));
  const el = document.elementFromPoint(touch.clientX, touch.clientY);
  if (!el) return;
  const targetCard = el.closest('.sidebar-card');
  const targetGroup = el.closest('.sidebar-project-group');
  const allP = (typeof allProjects !== 'undefined' ? allProjects : []);
  const sourceProj = allP.find(p => (p.voices || []).includes(fromVoice));
  if (targetCard && targetCard.dataset.voiceId && targetCard.dataset.voiceId !== fromVoice) {
    const toVoice = targetCard.dataset.voiceId;
    const targetProj = allP.find(p => (p.voices || []).includes(toVoice));
    if (!targetProj) return;
    if (!sourceProj || sourceProj.slug !== targetProj.slug) {
      _moveAgentToProject(fromVoice, targetProj.slug); return;
    }
    const voices = targetProj.voices;
    const fromIdx = voices.indexOf(fromVoice);
    if (fromIdx < 0) return;
    voices.splice(fromIdx, 1);
    const rect = targetCard.getBoundingClientRect();
    const newToIdx = voices.indexOf(toVoice);
    const insertIdx = touch.clientY < rect.top + rect.height / 2 ? newToIdx : newToIdx + 1;
    voices.splice(insertIdx, 0, fromVoice);
    renderSidebar();
    fetch(`/api/projects/${targetProj.slug}/voices`, {
      method: 'PUT', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ voices }),
    }).catch(err => console.error('Failed to save agent order:', err));
  } else if (targetGroup) {
    const targetSlug = targetGroup.dataset.projectSlug;
    if (targetSlug && sourceProj && sourceProj.slug !== targetSlug)
      _moveAgentToProject(fromVoice, targetSlug);
  }
}

async function _reorderProjects(fromSlug, toSlug) {
  if (typeof allProjects === 'undefined' || fromSlug === toSlug) return;
  const fromIdx = allProjects.findIndex(p => p.slug === fromSlug);
  const toIdx = allProjects.findIndex(p => p.slug === toSlug);
  if (fromIdx < 0 || toIdx < 0) return;
  const [moved] = allProjects.splice(fromIdx, 1);
  allProjects.splice(toIdx, 0, moved);
  renderSidebar();
  // Persist order to settings
  const order = allProjects.map(p => p.slug);
  try {
    await fetch('/api/settings', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ project_order: order }),
    });
  } catch (e) { console.error('Failed to save project order:', e); }
}

function _createAgentCard(voiceId, name, state) {
  const card = document.createElement('div');
  card.className = 'sidebar-card';
  card.dataset.voiceId = voiceId;
  card.draggable = true;

  // Drag-and-drop for cross-project moves
  card.addEventListener('dragstart', (e) => {
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', voiceId);
    card.classList.add('dragging');
  });
  card.addEventListener('dragend', () => { card.classList.remove('dragging'); });
  card.addEventListener('dragover', (e) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    if (e.dataTransfer.types.includes('application/x-project-slug')) return;
    const rect = card.getBoundingClientRect();
    const midY = rect.top + rect.height / 2;
    card.classList.toggle('drag-above', e.clientY < midY);
    card.classList.toggle('drag-below', e.clientY >= midY);
  });
  card.addEventListener('dragleave', () => {
    card.classList.remove('drag-above', 'drag-below');
  });
  card.addEventListener('drop', (e) => {
    e.preventDefault();
    e.stopPropagation();
    card.classList.remove('drag-above', 'drag-below');
    const fromVoice = e.dataTransfer.getData('text/plain');
    if (!fromVoice || fromVoice === voiceId) return;
    if (e.dataTransfer.getData('application/x-project-slug')) return;

    const allP = (typeof allProjects !== 'undefined' ? allProjects : []);
    const targetProj = allP.find(p => (p.voices || []).includes(voiceId));
    const sourceProj = allP.find(p => (p.voices || []).includes(fromVoice));
    if (!targetProj) return;
    // Cross-project drop — move agent to this card's project
    if (!sourceProj || sourceProj.slug !== targetProj.slug) {
      _moveAgentToProject(fromVoice, targetProj.slug); return;
    }
    // Same-project reorder
    const voices = targetProj.voices;
    const fromIdx = voices.indexOf(fromVoice);
    if (fromIdx < 0) return;
    voices.splice(fromIdx, 1);
    const rect = card.getBoundingClientRect();
    const newToIdx = voices.indexOf(voiceId);
    const insertIdx = e.clientY < rect.top + rect.height / 2 ? newToIdx : newToIdx + 1;
    voices.splice(insertIdx, 0, fromVoice);
    renderSidebar();
    fetch(`/api/projects/${targetProj.slug}/voices`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ voices }),
    }).catch(err => console.error('Failed to save agent order:', err));
  });

  const icon = document.createElement('div');
  icon.className = 'sb-icon';
  const iconVal = voiceIcon(voiceId);
  if (iconVal.startsWith('<')) { icon.innerHTML = iconVal; } else { icon.textContent = iconVal; }
  const vc = voiceColor(voiceId);
  icon.style.background = vc + '20';
  icon.style.color = vc;
  const info = document.createElement('div');
  info.className = 'sb-info';
  const nameEl = document.createElement('div');
  nameEl.className = 'sb-name';
  nameEl.textContent = name;
  nameEl.style.color = vc;
  const statusEl2 = document.createElement('div');
  statusEl2.className = 'sb-status';
  const dot2 = document.createElement('span');
  dot2.className = 'sb-dot';
  const labelEl = document.createElement('span');
  labelEl.textContent = state.statusLabel;
  statusEl2.appendChild(dot2);
  statusEl2.appendChild(labelEl);
  info.appendChild(nameEl);
  if (state.projectArea) {
    const repoEl = document.createElement('div');
    repoEl.className = 'sb-repo';
    repoEl.textContent = state.projectArea;
    info.appendChild(repoEl);
  }
  if (state.roleText) {
    const roleEl = document.createElement('div');
    roleEl.className = 'sb-role';
    roleEl.textContent = state.roleText;
    info.appendChild(roleEl);
  }
  if (state.taskText) {
    const taskEl = document.createElement('div');
    taskEl.className = 'sb-task';
    taskEl.textContent = state.taskText;
    info.appendChild(taskEl);
  }
  if (state.isCompacting) {
    const compactEl = document.createElement('div');
    compactEl.className = 'sb-compacting';
    compactEl.textContent = 'Compacting…';
    info.appendChild(compactEl);
  }
  info.appendChild(statusEl2);
  card.appendChild(icon);
  card.appendChild(info);
  if (state.stateClass) card.classList.add(state.stateClass);
  if (state.isSelected) card.classList.add('selected');
  if (state.hasUnread) {
    const badge = document.createElement('span');
    badge.className = 'sb-unread';
    card.appendChild(badge);
  }
  card._voiceSession = state.session;
  card._voiceSpawning = state.isSpawning;
  card.onclick = () => {
    if (card._voiceSpawning) return;
    if (card._voiceSession) { switchTab(card._voiceSession.session_id, true); }
    else { spawnSession(voiceId); }
  };
  card.oncontextmenu = (e) => {
    e.preventDefault();
    if (card._voiceSession) { showContextMenu(e, card._voiceSession.session_id, voiceId); }
    else { showContextMenu(e, null, voiceId); }
  };
  let lpTimer = null, lpFired = false, touchDragging = false;
  let touchStartX = 0, touchStartY = 0;
  card.addEventListener('touchstart', (e) => {
    lpFired = false; touchDragging = false;
    const touch = e.touches[0];
    touchStartX = touch.clientX; touchStartY = touch.clientY;
    lpTimer = setTimeout(() => {
      lpTimer = null; lpFired = true;
      // Visual feedback only — menu appears on lift
      card.classList.add('long-press-active');
    }, 500);
  }, { passive: true });
  card.addEventListener('touchmove', (e) => {
    const touch = e.touches[0];
    if (!lpTimer && !lpFired && !touchDragging) return; // not in long-press flow
    if (lpTimer) {
      // Still in grace period — cancel if finger moved too far (scrolling)
      if (Math.hypot(touch.clientX - touchStartX, touch.clientY - touchStartY) > 8) {
        clearTimeout(lpTimer); lpTimer = null;
      }
      return;
    }
    if (!lpFired) return; // timer cancelled (scroll gesture)
    // Long-press fired, no context menu — intentional movement (>14px) starts drag
    if (!touchDragging) {
      if (Math.hypot(touch.clientX - touchStartX, touch.clientY - touchStartY) < 14) return;
      touchDragging = true;
      _touchDragStart(voiceId, touch);
    }
    e.preventDefault();
    _touchDragMove(touch);
  }, { passive: false });
  const _cancelTouchDrag = () => {
    if (lpTimer) { clearTimeout(lpTimer); lpTimer = null; }
    if (touchDragging && _touchDrag) { _touchDrag.ghost.remove(); _touchDrag = null; }
    document.querySelectorAll('.drag-above,.drag-below,.drag-over-group').forEach(el =>
      el.classList.remove('drag-above', 'drag-below', 'drag-over-group'));
    card.classList.remove('long-press-active');
    touchDragging = false; lpFired = false;
  };
  card.addEventListener('touchend', (e) => {
    if (lpTimer) { clearTimeout(lpTimer); lpTimer = null; }
    card.classList.remove('long-press-active');
    if (touchDragging) {
      e.preventDefault();
      _touchDragEnd(e.changedTouches[0]);
      touchDragging = false; lpFired = false; return;
    }
    if (lpFired) {
      // Long-press was held — show context menu now that finger is off screen
      e.preventDefault();
      const t = e.changedTouches[0];
      const fakeEvent = { preventDefault(){}, stopPropagation(){}, clientX: t.clientX, clientY: Math.max(10, t.clientY - 40) };
      if (card._voiceSession) { showContextMenu(fakeEvent, card._voiceSession.session_id, voiceId); }
      else { showContextMenu(fakeEvent, null, voiceId); }
    }
    lpFired = false;
  });
  card.addEventListener('touchcancel', _cancelTouchDrag);
  return card;
}

// Move an agent to a different project via API
async function _moveAgentToProject(voiceId, targetProjectSlug) {
  const targetProject = (typeof allProjects !== 'undefined' ? allProjects : []).find(p => p.slug === targetProjectSlug);
  const projectName = targetProject ? (targetProject.name || targetProjectSlug) : targetProjectSlug;
  // Find the session for this voice
  let session = null;
  for (const [, s] of sessions) {
    if (s.voice === voiceId) { session = s; break; }
  }
  try {
    // Update project status on session if active
    if (session) {
      await fetch(`/api/project-status/${session.session_id}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ project: projectName, repo: session.project_repo || '' }),
      });
    }
    // Update agents.json
    await fetch(`/api/agents/${voiceId}/assign`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ project: targetProjectSlug }),
    });
    // Move voice between project voice lists
    if (typeof allProjects !== 'undefined') {
      for (const proj of allProjects) {
        const idx = (proj.voices || []).indexOf(voiceId);
        if (idx >= 0) {
          proj.voices.splice(idx, 1);
          // Persist removal
          fetch(`/api/projects/${proj.slug}/voices`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ voices: proj.voices }),
          }).catch(e => console.warn('voice remove:', e));
        }
      }
      if (targetProject && targetProject.voices) {
        targetProject.voices.push(voiceId);
        // Persist addition
        fetch(`/api/projects/${targetProjectSlug}/voices`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ voices: targetProject.voices }),
        }).catch(e => console.warn('voice add:', e));
      }
    }
    renderSidebar();
  } catch (e) {
    console.error('Failed to move agent to project:', e);
  }
}

function renderSidebar() {
  const list = document.getElementById('sidebar-list');
  // Preserve scroll position across re-renders and CSS transitions
  const _savedScroll = list ? list.scrollTop : 0;
  requestAnimationFrame(() => { if (list) list.scrollTop = _savedScroll; });
  const projects = (typeof allProjects !== 'undefined' && allProjects.length > 0) ? allProjects : [];

  // No projects — show only active sessions or welcome
  if (projects.length === 0) {
    const activeVoices = new Set();
    for (const [, s] of sessions) {
      if (s.voice) activeVoices.add(s.voice);
    }
    if (activeVoices.size === 0) {
      list.innerHTML = '';
      const welcome = document.createElement('div');
      welcome.style.cssText = 'padding:24px 16px;text-align:center;color:var(--text-secondary,#888);font-size:0.9em;';
      welcome.innerHTML = '<div style="font-size:1.3em;margin-bottom:8px;">Welcome to ClawMux</div>'
        + '<div style="margin-bottom:16px;">Create a folder to get started</div>'
        + '<button style="padding:8px 20px;border-radius:8px;border:1px solid #4a9eff;background:none;color:#4a9eff;cursor:pointer;font-family:inherit;font-size:0.95em;" onclick="_promptNewProject()">+ New Folder</button>';
      list.appendChild(welcome);
      return;
    }
    // Flat list of active agents (no projects)
    _renderFlatAgentList(list, [...activeVoices]);
    return;
  }

  // Grouped view: one collapsible section per folder
  const existingGroups = new Map();
  for (const el of list.querySelectorAll('.sidebar-project-group')) {
    existingGroups.set(el.dataset.projectSlug, el);
  }

  // Remove stale groups and non-group children (except focus card etc.)
  const projectSlugs = new Set(projects.map(p => p.slug));
  for (const child of [...list.children]) {
    if (child.classList.contains('sidebar-project-group')) {
      if (!projectSlugs.has(child.dataset.projectSlug)) child.remove();
    } else if (!child.id) {
      // Remove orphan elements (like old flat cards or welcome message)
      child.remove();
    }
  }

  for (let pi = 0; pi < projects.length; pi++) {
    const proj = projects[pi];
    const slug = proj.slug;
    const isCollapsed = _collapsedProjects.has(slug);
    const voices = (proj.voices || []).map(v => [v, VOICE_NAMES[v] || v.replace(/^[a-z]{2}_/, '').replace(/^./, c => c.toUpperCase())]);

    // Count active agents
    let activeCount = 0;
    for (const [vid] of voices) {
      for (const [, s] of sessions) {
        if (s.voice === vid) { activeCount++; break; }
      }
    }

    // Default folder always stays visible (drop target for agents, even when empty)

    let group = existingGroups.get(slug);
    if (!group) {
      group = document.createElement('div');
      group.className = 'sidebar-project-group';
      group.dataset.projectSlug = slug;

      // Project header (draggable for reordering)
      const header = document.createElement('div');
      header.className = 'sidebar-project-header';
      header.draggable = true;
      header.innerHTML = '<span class="project-chevron">&#9660;</span>'
        + '<span class="project-name"></span>'
        + '<span class="project-agent-count"></span>'
        + '<button class="project-monitor-btn" title="Monitor folder"><svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor"><rect x="0.5" y="1.5" width="15" height="13" rx="2" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M3.5 6l2.5 2.5L3.5 11" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/><line x1="8" y1="11" x2="12" y2="11" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg></button>';
      header.addEventListener('click', (e) => {
        if (e.target.closest('.project-monitor-btn')) return;
        _toggleProjectCollapse(slug);
      });
      header.querySelector('.project-monitor-btn').addEventListener('click', (e) => {
        e.stopPropagation();
        if (typeof openMonitorPanel === 'function') openMonitorPanel('folder', slug);
      });
      header.addEventListener('dragstart', (e) => {
        e.stopPropagation();
        _draggingProjectSlug = slug;
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('application/x-project-slug', slug);
        group.classList.add('dragging');
      });
      header.addEventListener('dragend', () => {
        _draggingProjectSlug = null;
        group.classList.remove('dragging');
      });
      group.appendChild(header);

      // Agent container
      const agentContainer = document.createElement('div');
      agentContainer.className = 'sidebar-project-agents';
      group.appendChild(agentContainer);

      // Drop zone: allow dropping agents or project groups
      group.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        group.classList.add('drag-over-group');
      });
      group.addEventListener('dragleave', (e) => {
        if (!group.contains(e.relatedTarget)) {
          group.classList.remove('drag-over-group');
        }
      });
      group.addEventListener('drop', (e) => {
        e.preventDefault();
        group.classList.remove('drag-over-group');
        // Check if this is a project reorder
        const fromProject = e.dataTransfer.getData('application/x-project-slug');
        if (fromProject && fromProject !== slug) {
          _reorderProjects(fromProject, slug);
          return;
        }
        // Otherwise it's an agent drop
        const fromVoice = e.dataTransfer.getData('text/plain');
        if (!fromVoice) return;
        if ((proj.voices || []).includes(fromVoice)) return;
        _moveAgentToProject(fromVoice, slug);
      });
    }

    // Update header text
    const nameEl = group.querySelector('.project-name');
    const countEl = group.querySelector('.project-agent-count');
    const chevron = group.querySelector('.project-chevron');
    if (nameEl) nameEl.textContent = proj.name || slug;
    if (countEl) countEl.textContent = `(${activeCount}/${voices.length})`;
    if (chevron) chevron.classList.toggle('collapsed', isCollapsed);

    // Update agent cards in container
    const agentContainer = group.querySelector('.sidebar-project-agents');
    if (isCollapsed) {
      agentContainer.classList.add('collapsed');
      agentContainer.style.maxHeight = '0';
    } else {
      agentContainer.classList.remove('collapsed');
      const currentCards = new Map();
      for (const card of agentContainer.querySelectorAll('.sidebar-card')) { currentCards.set(card.dataset.voiceId, card); }
      const voiceIds = new Set(voices.map(([id]) => id));
      for (const child of [...agentContainer.children]) {
        if (child.classList.contains('sidebar-card') && child.dataset.voiceId && !voiceIds.has(child.dataset.voiceId)) child.remove();
      }
      for (let i = 0; i < voices.length; i++) {
        const [voiceId, name] = voices[i];
        const st = _sidebarState(voiceId);
        let el = currentCards.get(voiceId);
        if (el) _updateSidebarCard(el, voiceId, st);
        else el = _createAgentCard(voiceId, name, st);
        if (agentContainer.children[i] !== el) agentContainer.insertBefore(el, agentContainer.children[i] || null);
      }
      agentContainer.style.maxHeight = agentContainer.scrollHeight + 'px';
    }

    // Insert group in correct position
    if (list.children[pi] !== group) {
      if (pi < list.children.length) list.insertBefore(group, list.children[pi]);
      else list.appendChild(group);
    }
  }

  // Group chats section (rendered below all projects)
  _renderGroupChatSection(list, projects.length);
}

function _renderGroupChatSection(list, afterIndex) {
  const gc = typeof groupChats !== 'undefined' ? groupChats : new Map();

  // Find or create the section — stable ID prevents orphan-removal from deleting it each render
  let section = document.getElementById('sidebar-gc-section');
  if (!section) {
    section = document.createElement('div');
    section.id = 'sidebar-gc-section';
    section.className = 'sidebar-gc-section';
    const hdr = document.createElement('div');
    hdr.className = 'sidebar-gc-header';
    hdr.innerHTML = '<span>Group Chats</span>';
    const createBtn = document.createElement('button');
    createBtn.className = 'sidebar-gc-new-btn';
    createBtn.title = 'New group chat';
    createBtn.textContent = '+';
    createBtn.onclick = () => _promptNewGroupChat();
    hdr.appendChild(createBtn);
    section.appendChild(hdr);
    list.appendChild(section);
  }

  // Diff: build map of existing cards
  const existingCards = new Map();
  for (const el of section.querySelectorAll('.sidebar-gc-card')) {
    existingCards.set(el.dataset.gcId, el);
  }

  const validIds = new Set();
  for (const g of gc.values()) {
    validIds.add(g.id);
    let card = existingCards.get(g.id);
    if (!card) {
      // Create new card and attach events once
      card = document.createElement('div');
      card.className = 'sidebar-gc-card';
      card.dataset.gcId = g.id;
      card.draggable = true;

      const avatars = document.createElement('div');
      avatars.className = 'gc-avatars';
      const members = g.members || [];
      avatars.dataset.count = members.length;
      for (const m of members) {
        const dot = document.createElement('div');
        dot.className = 'gc-avatar';
        const vc = (typeof voiceColor === 'function') ? voiceColor(m.voice) : '#4a9eff';
        dot.style.background = vc + '22';
        dot.style.color = vc;
        const ico = (typeof voiceIcon === 'function') ? voiceIcon(m.voice) : (m.label ? m.label[0].toUpperCase() : '?');
        if (ico && ico.startsWith('<')) dot.innerHTML = ico;
        else dot.textContent = ico || (m.label ? m.label[0].toUpperCase() : '?');
        avatars.appendChild(dot);
      }

      const info = document.createElement('div');
      info.className = 'gc-info';
      const nameEl = document.createElement('div');
      nameEl.className = 'gc-name';
      nameEl.textContent = g.name;
      const membersEl = document.createElement('div');
      membersEl.className = 'gc-members-text';
      membersEl.textContent = (g.members || []).map(m => m.label).join(', ') || 'No members';
      info.appendChild(nameEl);
      info.appendChild(membersEl);

      card.appendChild(avatars);
      card.appendChild(info);
      card.onclick = () => { if (typeof openGroupChat === 'function') openGroupChat(g.id); };

      card.addEventListener('dragstart', e => {
        _gcDragId = g.id;
        e.dataTransfer.effectAllowed = 'move';
        card.classList.add('dragging');
      });
      card.addEventListener('dragend', () => {
        _gcDragId = null;
        card.classList.remove('dragging');
        section.querySelectorAll('.sidebar-gc-card').forEach(c => c.classList.remove('drag-over'));
      });
      card.addEventListener('dragover', e => {
        if (!_gcDragId || _gcDragId === g.id) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        section.querySelectorAll('.sidebar-gc-card').forEach(c => c.classList.remove('drag-over'));
        card.classList.add('drag-over');
      });
      card.addEventListener('dragleave', () => card.classList.remove('drag-over'));
      card.addEventListener('drop', e => {
        e.preventDefault();
        card.classList.remove('drag-over');
        if (!_gcDragId || _gcDragId === g.id) return;
        _reorderGroupChats(_gcDragId, g.id);
        _gcDragId = null;
      });

      section.appendChild(card);
    }
    // Update active state in place
    const isActive = typeof activeGroupId !== 'undefined' && activeGroupId === g.id;
    card.classList.toggle('active', isActive);
  }

  // Remove cards for deleted group chats
  for (const [id, el] of existingCards) {
    if (!validIds.has(id)) el.remove();
  }
}

let _gcDragId = null;

async function _reorderGroupChats(fromId, toId) {
  const gc = typeof groupChats !== 'undefined' ? groupChats : new Map();
  const entries = [...gc.entries()];
  const fromIdx = entries.findIndex(([, g]) => g.id === fromId);
  const toIdx = entries.findIndex(([, g]) => g.id === toId);
  if (fromIdx < 0 || toIdx < 0) return;
  // Move fromIdx to toIdx
  const [moved] = entries.splice(fromIdx, 1);
  entries.splice(toIdx, 0, moved);
  gc.clear();
  for (const [k, v] of entries) gc.set(k, v);
  renderSidebar();
  // Persist order to backend
  try {
    await fetch('/api/groupchats/reorder', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ order: entries.map(([, g]) => g.id) }),
    });
  } catch (e) { console.error('[gc reorder]', e); }
}

async function _promptNewGroupChat() {
  const name = prompt('Group chat name:');
  if (!name || !name.trim()) return;
  try {
    const resp = await fetch('/api/groupchats', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name.trim() }),
    });
    const data = await resp.json();
    if (data.error) { alert(data.error); return; }
    if (typeof groupChats !== 'undefined') groupChats.set(data.name.toLowerCase(), data);
    renderSidebar();
  } catch (e) { console.error('Failed to create group chat:', e); }
}

// Fallback: flat list of agents when no projects exist
function _renderFlatAgentList(list, voiceIds) {
  const allVoices = voiceIds.map(v => [v, VOICE_NAMES[v] || v.replace(/^[a-z]{2}_/, '').replace(/^./, c => c.toUpperCase())]);
  allVoices.sort((a, b) => a[1].localeCompare(b[1]));

  const currentVoiceIds = new Set(allVoices.map(([id]) => id));
  for (const card of [...list.children]) {
    if (card.dataset && card.dataset.voiceId && !currentVoiceIds.has(card.dataset.voiceId)) card.remove();
    if (card.classList && card.classList.contains('sidebar-project-group')) card.remove();
  }
  const existingCards = new Map();
  for (const card of list.children) {
    if (card.dataset && card.dataset.voiceId) existingCards.set(card.dataset.voiceId, card);
  }
  for (let i = 0; i < allVoices.length; i++) {
    const [voiceId, name] = allVoices[i];
    const state = _sidebarState(voiceId);
    let card = existingCards.get(voiceId);
    if (card) {
      _updateSidebarCard(card, voiceId, state);
      if (list.children[i] !== card) list.insertBefore(card, list.children[i]);
    } else {
      card = _createAgentCard(voiceId, name, state);
      if (i < list.children.length) list.insertBefore(card, list.children[i]);
      else list.appendChild(card);
    }
  }
}

async function reorderSidebarVoice(fromVoice, toVoice) {
  // Get current voice order from the sidebar
  const list = document.getElementById('sidebar-list');
  const voices = [...list.querySelectorAll('.sidebar-card')].map(c => c.dataset.voiceId).filter(Boolean);
  const fromIdx = voices.indexOf(fromVoice);
  const toIdx = voices.indexOf(toVoice);
  if (fromIdx < 0 || toIdx < 0) return;
  // Move fromVoice to toVoice's position
  voices.splice(fromIdx, 1);
  voices.splice(toIdx, 0, fromVoice);
  // Update local state and re-render immediately
  if (currentProjectVoices) currentProjectVoices = voices;
  renderSidebar();
  // Persist to backend
  try {
    await fetch(`/api/projects/${currentProject}/voices`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ voices }),
    });
  } catch (e) { console.error('Failed to save voice order:', e); }
}

// Legacy compatibility
function renderVoiceGrid() { renderSidebar(); }
function renderVoiceGridIfActive() { renderSidebar(); }

// --- OpenClaw Agents Sidebar ---
let _openclawAgents = [];  // [{name, id, connected, sessionId}]
let _openclawCollapsed = false;
let _openclawFetchTimer = null;

function _toggleOpenClawCollapse() {
  _openclawCollapsed = !_openclawCollapsed;
  renderOpenClawSidebar();
}

async function fetchOpenClawAgents() {
  try {
    const resp = await fetch('/api/openclaw/agents');
    if (!resp.ok) return;
    const data = await resp.json();
    const agents = data.agents || [];
    _openclawAgents = agents.map(a => {
      // Display name: identity.name > name > id
      const displayName = (a.identity && a.identity.name) || a.name || a.id;
      // Check if this agent has an active session (connected)
      // OpenClaw session IDs are prefixed: "oc-<name>" (e.g. "oc-speedy")
      const expectedSid = 'oc-' + displayName.toLowerCase();
      let sessionId = null;
      for (const [sid, s] of sessions) {
        if (s.backend === 'openclaw' && (sid === expectedSid || s.label === displayName)) {
          sessionId = sid;
          break;
        }
      }
      return { name: displayName, id: a.id, connected: !!sessionId, sessionId };
    });
    renderOpenClawSidebar();
  } catch (e) {
    console.warn('Failed to fetch OpenClaw agents:', e);
  }
}

function startOpenClawPolling() {
  if (_openclawFetchTimer) return;
  fetchOpenClawAgents();
  _openclawFetchTimer = setInterval(fetchOpenClawAgents, 30000);
}

function renderOpenClawSidebar() {
  const section = document.getElementById('openclaw-section');
  const container = document.getElementById('openclaw-agents');
  const chevron = document.getElementById('openclaw-chevron');
  const countEl = document.getElementById('openclaw-count');
  if (!section || !container) return;

  if (_openclawAgents.length === 0) {
    section.style.display = 'none';
    return;
  }
  section.style.display = '';
  const connected = _openclawAgents.filter(a => a.connected).length;
  countEl.textContent = connected + '/' + _openclawAgents.length;
  chevron.textContent = _openclawCollapsed ? '\u25B6' : '\u25BC';

  if (_openclawCollapsed) {
    container.style.display = 'none';
    return;
  }
  container.style.display = '';

  container.innerHTML = _openclawAgents.map(agent => {
    const sid = agent.sessionId || agent.id;
    const selected = activeSessionId === sid ? ' selected' : '';
    return `<div class="openclaw-card${selected}" data-openclaw-id="${agent.id}" onclick="switchToOpenClawAgent('${agent.id}', '${agent.name}')">
      <span class="openclaw-dot"></span>
      <span class="openclaw-name">${agent.name}</span>
    </div>`;
  }).join('');
}

async function switchToOpenClawAgent(agentId, agentName) {
  // If already connected, switch to existing session
  const agent = _openclawAgents.find(a => a.id === agentId);
  if (agent && agent.sessionId && sessions.has(agent.sessionId)) {
    switchTab(agent.sessionId);
    return;
  }
  // Connect via API — creates session in hub
  try {
    const resp = await fetch('/api/openclaw/connect', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: agentName, agent_id: agentId }),
    });
    if (!resp.ok) {
      console.error('OpenClaw connect failed:', await resp.text());
      return;
    }
    const data = await resp.json();
    const sessionId = data.session_id;
    // Session will appear via WS session_spawned event — wait briefly then switch
    const waitForSession = () => {
      if (sessions.has(sessionId)) {
        switchTab(sessionId);
        fetchOpenClawAgents();  // refresh connected state
      } else {
        setTimeout(waitForSession, 200);
      }
    };
    waitForSession();
  } catch (e) {
    console.error('OpenClaw connect error:', e);
  }
}
