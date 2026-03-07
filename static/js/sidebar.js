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
  // Project 2+3 use default icon (microphone emoji) via voiceIcon() fallback
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
  statusEl.textContent = text;
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
        (s.project_area ? '<div style="opacity:0.7;">' + s.project_area + '</div>' : '');
      return;
    }
  }
  el.innerHTML = '';
}

function updateLayout() {
  renderSidebar(); // always keep sidebar up to date
  if (debugActive) return; // debug panel handles its own layout
  const inChat = activeSessionId && sessions.has(activeSessionId);
  document.getElementById('welcome-view').style.display = (!inChat && !focusMode) ? 'flex' : 'none';
  document.getElementById('focus-view').style.display = focusMode ? 'flex' : 'none';
  chatArea.style.display = inChat ? 'flex' : 'none';
  document.getElementById('debug-panel').style.display = 'none';
  document.getElementById('settings-page').style.display = 'none';
  if (inChat) {
    if (inputMode === 'typing') {
      controls.style.display = 'none';
      textInputBar.classList.add('active');
    } else {
      controls.style.display = 'grid';
      textInputBar.classList.remove('active');
    }
  } else {
    controls.style.display = 'none';
    textInputBar.classList.remove('active');
  }
}

// --- Welcome view (no chat selected) ---
function showWelcome() {
  stopThinkingSound();
  if (recording) stopRecording(false); // send recording before switching
  stopActiveAudio();
  stopElapsedTimer();
  pendingListenSessionId = null;
  activeSessionId = null;
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
// Valid states: 'idle', 'working', 'starting', 'offline' (server state only — no speaking/listening)
function setSessionSidebarState(sessionId, newState) {
  const s = sessions.get(sessionId);
  if (!s) return;
  // Normalize legacy state names
  if (newState === 'ready') newState = 'idle';
  if (newState === 'thinking') newState = 'working';
  if (newState === 'active') newState = 'idle';
  const prev = s.sidebarState || 'idle';
  if (prev === newState) return;
  s.sidebarState = newState;
  renderSidebar();
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
  fetch(`/api/sessions/${sessionId}/mark-read`, { method: 'POST' }).catch(() => {});
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
    } else if (st === 'working') {
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
  const projectArea = session && session.project_area ? session.project_area : '';
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
  let lpTimer = null, lpFired = false;
  card.addEventListener('touchstart', (e) => {
    lpFired = false;
    lpTimer = setTimeout(() => {
      lpTimer = null; lpFired = true;
      card.classList.add('long-press-active');
      const touch = e.touches[0];
      const fakeEvent = { preventDefault(){}, stopPropagation(){}, clientX: touch.clientX, clientY: touch.clientY };
      if (card._voiceSession) { showContextMenu(fakeEvent, card._voiceSession.session_id, voiceId); }
      else { showContextMenu(fakeEvent, null, voiceId); }
      setTimeout(() => card.classList.remove('long-press-active'), 200);
    }, 500);
  }, { passive: true });
  card.addEventListener('touchend', (e) => {
    if (lpTimer) clearTimeout(lpTimer); lpTimer = null;
    if (lpFired) { e.preventDefault(); lpFired = false; }
  });
  card.addEventListener('touchmove', () => { if (lpTimer) clearTimeout(lpTimer); lpTimer = null; });
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
        body: JSON.stringify({ project: projectName, area: session.project_area || '' }),
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
          }).catch(() => {});
        }
      }
      if (targetProject && targetProject.voices) {
        targetProject.voices.push(voiceId);
        // Persist addition
        fetch(`/api/projects/${targetProjectSlug}/voices`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ voices: targetProject.voices }),
        }).catch(() => {});
      }
    }
    renderSidebar();
  } catch (e) {
    console.error('Failed to move agent to project:', e);
  }
}

function renderSidebar() {
  const list = document.getElementById('sidebar-list');
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
        + '<div style="margin-bottom:16px;">Create a project to get started</div>'
        + '<button style="padding:8px 20px;border-radius:8px;border:1px solid #4a9eff;background:none;color:#4a9eff;cursor:pointer;font-family:inherit;font-size:0.95em;" onclick="_promptNewProject()">+ New Project</button>';
      list.appendChild(welcome);
      return;
    }
    // Flat list of active agents (no projects)
    _renderFlatAgentList(list, [...activeVoices]);
    return;
  }

  // Grouped view: one collapsible section per project
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
        + '<span class="project-agent-count"></span>';
      header.addEventListener('click', () => _toggleProjectCollapse(slug));
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
      // Render agent cards
      const currentCards = new Map();
      for (const card of agentContainer.querySelectorAll('.sidebar-card')) {
        currentCards.set(card.dataset.voiceId, card);
      }
      // Remove stale cards
      const voiceIds = new Set(voices.map(([id]) => id));
      for (const card of [...agentContainer.children]) {
        if (card.dataset.voiceId && !voiceIds.has(card.dataset.voiceId)) card.remove();
      }

      for (let i = 0; i < voices.length; i++) {
        const [voiceId, name] = voices[i];
        const state = _sidebarState(voiceId);
        let card = currentCards.get(voiceId);
        if (card) {
          _updateSidebarCard(card, voiceId, state);
          if (agentContainer.children[i] !== card) agentContainer.insertBefore(card, agentContainer.children[i]);
        } else {
          card = _createAgentCard(voiceId, name, state);
          if (i < agentContainer.children.length) agentContainer.insertBefore(card, agentContainer.children[i]);
          else agentContainer.appendChild(card);
        }
      }
      agentContainer.style.maxHeight = agentContainer.scrollHeight + 'px';
    }

    // Insert group in correct position
    if (list.children[pi] !== group) {
      if (pi < list.children.length) list.insertBefore(group, list.children[pi]);
      else list.appendChild(group);
    }
  }
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
