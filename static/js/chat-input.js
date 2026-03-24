// ClawMux — Chat Input Module
// Slash commands, @mention file picker, text input, drag-and-drop, context menus.
// Dependencies: state.js (sessions, activeSessionId, ws), hub.html (textInput, textSendBtn)

// === Slash Command Menu ===
const _slashCommands = [
  { cmd: '/compact', desc: 'Compact the conversation' },
  { cmd: '/model', desc: 'Change model' },
  { cmd: '/effort', desc: 'Change effort level' },
  { cmd: '/help', desc: 'Show help' },
  { cmd: '/clear', desc: 'Clear the chat display' },
  { cmd: '/bug', desc: 'Report a bug' },
  { cmd: '/doctor', desc: 'Run health checks' },
  { cmd: '/init', desc: 'Reinitialize the session' },
  { cmd: '/config', desc: 'Open settings' },
];
const _slashMenu = document.getElementById('slash-menu');
let _slashActiveIdx = -1;

function _isSlashMenuBackend() {
  const s = typeof sessions !== 'undefined' ? sessions.get(activeSessionId) : null;
  return s && s.backend === 'claude-json';
}

function openSlashMenu() { _showSlashMenu('/'); }

function _showSlashMenu(filter) {
  const matches = _slashCommands.filter(c => c.cmd.startsWith(filter));
  if (!matches.length || !_isSlashMenuBackend()) { _hideSlashMenu(); return; }
  _slashMenu.innerHTML = '';
  matches.forEach((c, i) => {
    const el = document.createElement('div');
    el.className = 'slash-item' + (i === 0 ? ' active' : '');
    el.innerHTML = '<span class="slash-item-cmd">' + c.cmd + '</span><span class="slash-item-desc">' + c.desc + '</span>';
    el.addEventListener('click', () => _selectSlashCommand(c.cmd));
    _slashMenu.appendChild(el);
  });
  _slashActiveIdx = 0;
  _slashMenu.style.display = 'block';
}

function _hideSlashMenu() {
  _slashMenu.style.display = 'none';
  _slashActiveIdx = -1;
}

function _selectSlashCommand(cmd) {
  _hideSlashMenu();
  textInput.value = '';
  textInput.style.height = 'auto';
  textSendBtn.disabled = true;

  // Route each command to its action
  switch (cmd) {
    case '/effort':
      if (typeof toggleEffortPopup === 'function') toggleEffortPopup();
      break;
    case '/model':
      if (typeof toggleModelPopup === 'function') toggleModelPopup();
      break;
    case '/compact':
      // Send as text message — deliver_message writes to stdin
      textInput.value = '/compact';
      textSendBtn.disabled = false;
      sendTextMessage();
      break;
    case '/clear':
      { const ca = document.getElementById('chat-area');
        if (ca) ca.innerHTML = ''; }
      break;
    case '/bug':
      window.open('https://github.com/anthropics/claude-code/issues', '_blank');
      break;
    case '/doctor':
      // Send as text message — deliver_message writes to stdin
      textInput.value = '/doctor';
      textSendBtn.disabled = false;
      sendTextMessage();
      break;
    case '/init':
      if (activeSessionId) {
        fetch(`/api/sessions/${encodeURIComponent(activeSessionId)}/restart`, {
          method: 'POST',
        }).catch(e => console.error('Init failed:', e));
      }
      break;
    case '/config':
      if (typeof showSettingsPage === 'function') showSettingsPage();
      break;
    default:
      // Unknown command — send as text to agent
      textInput.value = cmd;
      textSendBtn.disabled = false;
      sendTextMessage();
  }
}

function _slashMenuNav(dir) {
  const items = _slashMenu.querySelectorAll('.slash-item');
  if (!items.length) return;
  items[_slashActiveIdx]?.classList.remove('active');
  _slashActiveIdx = (_slashActiveIdx + dir + items.length) % items.length;
  items[_slashActiveIdx]?.classList.add('active');
}

// === @Mention File Autocomplete ===
const _fileMenu = document.getElementById('file-menu');
let _fileActiveIdx = -1;
let _fileAtPos = -1;       // cursor position of the triggering @
let _fileFetchTimer = null; // debounce timer

function _getAtMention() {
  // Find the @ before the cursor with a partial query (no spaces)
  const cur = textInput.selectionStart;
  const val = textInput.value;
  for (let i = cur - 1; i >= 0; i--) {
    if (val[i] === '@') return { pos: i, query: val.slice(i + 1, cur) };
    if (val[i] === ' ' || val[i] === '\n') break;
  }
  return null;
}

async function _fetchFiles(query) {
  if (!activeSessionId) return [];
  try {
    const r = await fetch(`/api/sessions/${encodeURIComponent(activeSessionId)}/files?query=${encodeURIComponent(query)}`);
    if (!r.ok) return [];
    const data = await r.json();
    return data.files || [];
  } catch { return []; }
}

function _showFileMenu(files) {
  if (!files.length || !_isSlashMenuBackend()) {
    _hideFileMenu(); return;
  }
  _fileMenu.innerHTML = '';
  files.slice(0, 15).forEach((f, i) => {
    const path = typeof f === 'string' ? f : (f.path || f.name || '');
    const parts = path.split('/');
    const name = parts.pop();
    const dir = parts.length ? parts.join('/') + '/' : '';
    const el = document.createElement('div');
    el.className = 'file-item' + (i === 0 ? ' active' : '');
    el.dataset.path = path;
    el.innerHTML =
      '<span class="file-item-icon">📄</span>' +
      '<span class="file-item-name">' + (name || path) + '</span>' +
      (dir ? '<span class="file-item-dir">' + dir + '</span>' : '');
    el.addEventListener('click', () => _selectFile(path));
    _fileMenu.appendChild(el);
  });
  _fileActiveIdx = 0;
  _fileMenu.style.display = 'block';
}

function _hideFileMenu() {
  _fileMenu.style.display = 'none';
  _fileActiveIdx = -1;
  _fileAtPos = -1;
  if (_fileFetchTimer) { clearTimeout(_fileFetchTimer); _fileFetchTimer = null; }
}

function _selectFile(path) {
  const val = textInput.value;
  const before = val.slice(0, _fileAtPos);
  const after = val.slice(textInput.selectionStart);
  textInput.value = before + '@' + path + ' ' + after;
  const newCur = _fileAtPos + 1 + path.length + 1;
  textInput.setSelectionRange(newCur, newCur);
  textInput.style.height = 'auto';
  textInput.style.height = Math.min(textInput.scrollHeight, 120) + 'px';
  textSendBtn.disabled = !textInput.value.trim();
  _hideFileMenu();
  textInput.focus();
}

function _fileMenuNav(dir) {
  const items = _fileMenu.querySelectorAll('.file-item');
  if (!items.length) return;
  items[_fileActiveIdx]?.classList.remove('active');
  _fileActiveIdx = (_fileActiveIdx + dir + items.length) % items.length;
  items[_fileActiveIdx]?.classList.add('active');
  items[_fileActiveIdx]?.scrollIntoView({ block: 'nearest' });
}

// Auto-resize textarea + slash/file menu triggers
textInput.addEventListener('input', () => {
  textInput.style.height = 'auto';
  textInput.style.height = Math.min(textInput.scrollHeight, 120) + 'px';
  textSendBtn.disabled = !textInput.value.trim();

  // Slash command detection (only at start of input)
  const val = textInput.value;
  if (val.startsWith('/') && !val.includes(' ') && !val.includes('\n')) {
    _showSlashMenu(val);
    _hideFileMenu();
    return;
  } else {
    _hideSlashMenu();
  }

  // @mention file detection
  const mention = _getAtMention();
  if (mention && _isSlashMenuBackend()) {
    _fileAtPos = mention.pos;
    if (_fileFetchTimer) clearTimeout(_fileFetchTimer);
    _fileFetchTimer = setTimeout(async () => {
      const files = await _fetchFiles(mention.query);
      // Re-check mention is still valid after async
      const current = _getAtMention();
      if (current && current.pos === _fileAtPos) {
        _showFileMenu(files);
      }
    }, 150);
  } else {
    _hideFileMenu();
  }
});

// Send on Enter (Shift+Enter for newline) — desktop only
// On mobile, Enter inserts newline; the send button handles sending
textInput.addEventListener('keydown', (e) => {
  // Slash menu navigation
  if (_slashMenu.style.display !== 'none') {
    if (e.key === 'ArrowDown') { e.preventDefault(); _slashMenuNav(1); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); _slashMenuNav(-1); return; }
    if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) {
      e.preventDefault();
      const active = _slashMenu.querySelector('.slash-item.active');
      if (active) {
        const cmd = active.querySelector('.slash-item-cmd').textContent;
        _selectSlashCommand(cmd);
      }
      return;
    }
    if (e.key === 'Escape') { e.preventDefault(); _hideSlashMenu(); return; }
  }

  // File menu navigation
  if (_fileMenu.style.display !== 'none') {
    if (e.key === 'ArrowDown') { e.preventDefault(); _fileMenuNav(1); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); _fileMenuNav(-1); return; }
    if (e.key === 'Tab' || (e.key === 'Enter' && !e.shiftKey)) {
      e.preventDefault();
      const active = _fileMenu.querySelector('.file-item.active');
      if (active) _selectFile(active.dataset.path);
      return;
    }
    if (e.key === 'Escape') { e.preventDefault(); _hideFileMenu(); return; }
  }

  if (e.key === 'Enter' && !e.shiftKey && !isMobile) {
    e.preventDefault();
    sendTextMessage();
  }
});

// Dismiss menus on outside click
document.addEventListener('click', (e) => {
  if (!e.target.closest('#text-input-bar')) { _hideSlashMenu(); _hideFileMenu(); }
});

function sendTextMessage() {
  const text = textInput.value.trim();
  if (!text) return;
  // Group chat send
  if (typeof activeGroupId !== 'undefined' && activeGroupId) {
    const g = typeof groupChats !== 'undefined'
      ? [...groupChats.values()].find(x => x.id === activeGroupId)
      : null;
    if (!g) return;
    fetch(`/api/groupchats/${encodeURIComponent(g.name)}/message`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text }),
    }).catch(e => console.error('Group send failed:', e));
    textInput.value = '';
    textInput.style.height = 'auto';
    textSendBtn.disabled = true;
    return;
  }
  // Individual agent send
  if (!ws || ws.readyState !== WebSocket.OPEN || !activeSessionId) return;
  const s = sessions.get(activeSessionId);
  const isInterjection = s && s.sessionState !== 'listening';
  const msgType = isInterjection ? 'interjection' : 'text';
  // Add user message to chat immediately (before server echo) to ensure correct ordering
  const localMsgId = 'local-' + Date.now();
  if (typeof addMessage === 'function') {
    addMessage(activeSessionId, isInterjection ? 'user interjection' : 'user', text, { id: localMsgId });
  }
  ws.send(JSON.stringify({ session_id: activeSessionId, type: msgType, text }));
  textInput.value = '';
  textInput.style.height = 'auto';
  textSendBtn.disabled = true;
}

async function pasteFromClipboard() {
  try {
    const text = await navigator.clipboard.readText();
    if (text) {
      textInput.value = text;
      textInput.style.height = 'auto';
      textInput.style.height = Math.min(textInput.scrollHeight, 120) + 'px';
      textSendBtn.disabled = !text.trim();
      textInput.focus();
    }
  } catch(e) {
    console.warn('Clipboard read failed:', e);
  }
}

// --- Session elapsed time (disabled) ---
function startElapsedTimer() {}
function stopElapsedTimer() {}

// --- Long-press context menu (mobile) ---
let longPressTimer = null;
let longPressTarget = null;
let _activeContextMenu = null;

function _dismissContextMenu() {
  if (_activeContextMenu) { _activeContextMenu.remove(); _activeContextMenu = null; }
  if (longPressTarget) { longPressTarget.classList.remove('long-press-active'); longPressTarget = null; }
}

function _showContextMenu(msgEl, x, y) {
  _dismissContextMenu();
  const menu = document.createElement('div');
  menu.className = 'msg-context-menu';

  // Copy button
  const copyBtn = document.createElement('button');
  copyBtn.textContent = 'Copy';
  copyBtn.onclick = (e) => {
    e.stopPropagation();
    const text = msgEl.dataset.text || msgEl.textContent;
    navigator.clipboard.writeText(text).then(() => showCopyToast()).catch(() => {
      const ta = document.createElement('textarea');
      ta.value = text; ta.style.cssText = 'position:fixed;opacity:0';
      document.body.appendChild(ta); ta.select(); document.execCommand('copy'); document.body.removeChild(ta);
      showCopyToast();
    });
    _dismissContextMenu();
  };
  menu.appendChild(copyBtn);

  // Thumbs-up button — only for non-user messages with an ID
  const msgId = msgEl.dataset.msgId;
  const role = msgEl.className.match(/\b(user|assistant|system)\b/)?.[0];
  if (msgId && role !== 'user') {
    const ackBtn = document.createElement('button');
    ackBtn.textContent = '\uD83D\uDC4D';
    ackBtn.onclick = (e) => {
      e.stopPropagation();
      if (typeof activeGroupId !== 'undefined' && activeGroupId && typeof _sendGroupAck === 'function') {
        _sendGroupAck(msgId);
      } else {
        _sendUserAck(msgId);
      }
      _dismissContextMenu();
      showCopyToast('Ack sent');
    };
    menu.appendChild(ackBtn);
  }

  // Position near the touch point (account for scroll in chatArea)
  const chatRect = chatArea.getBoundingClientRect();
  menu.style.left = Math.min(x - chatRect.left, chatRect.width - 120) + 'px';
  menu.style.top = (y - chatRect.top + chatArea.scrollTop - 44) + 'px';
  chatArea.style.position = 'relative';
  chatArea.appendChild(menu);
  _activeContextMenu = menu;

  // Dismiss on tap outside
  setTimeout(() => {
    document.addEventListener('pointerdown', function _dismiss(ev) {
      if (!menu.contains(ev.target)) { _dismissContextMenu(); document.removeEventListener('pointerdown', _dismiss); }
    });
  }, 50);
}

let copyToastTimer = null;
let _notifyToastTimer = null;
function showToast(msg, level) {
  const toast = document.getElementById('notify-toast');
  if (!toast) return;
  toast.textContent = msg || '';
  toast.className = 'visible' + (level && level !== 'info' ? ` level-${level}` : '');
  if (_notifyToastTimer) clearTimeout(_notifyToastTimer);
  _notifyToastTimer = setTimeout(() => toast.classList.remove('visible'), 4000);
}

function showCopyToast(msg) {
  const toast = document.getElementById('copy-toast');
  toast.textContent = msg || 'Copied!';
  toast.classList.add('visible');
  if (copyToastTimer) clearTimeout(copyToastTimer);
  copyToastTimer = setTimeout(() => toast.classList.remove('visible'), 1500);
}

// Mobile long-press is now handled per-element in createMsgEl (matches sidebar pattern)

// Persist input mode
function saveInputMode() {
  try { localStorage.setItem('hub_input_mode', inputMode); } catch(e) {}
}
function restoreInputMode() {
  try {
    const saved = localStorage.getItem('hub_input_mode');
    if (saved === 'voice' || saved === 'typing') {
      inputMode = saved;
      applyInputMode();
    } else if (saved === 'auto' || saved === 'ptt') {
      // Migrate old mode names
      inputMode = 'voice';
      applyInputMode();
      saveInputMode();
    }
  } catch(e) {}
}

// --- Drag-and-drop file upload (desktop only) ---
function initDragDrop() {
  if (isMobile) return;

  let dragCounter = 0;
  let overlay = null;

  function getOverlay() {
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'drop-overlay';
      overlay.style.cssText = 'display:none;position:absolute;inset:0;background:rgba(58,134,255,0.08);border:2px dashed rgba(58,134,255,0.5);border-radius:12px;z-index:100;pointer-events:none;align-items:center;justify-content:center;font-size:1.1em;color:var(--text-secondary,#aaa);';
      overlay.textContent = 'Drop file to upload';
      chatArea.style.position = 'relative';
      chatArea.appendChild(overlay);
    }
    return overlay;
  }

  chatArea.addEventListener('dragenter', (e) => {
    e.preventDefault();
    if (!activeSessionId) return;
    dragCounter++;
    const s = sessions.get(activeSessionId);
    const name = s ? (s.label || voiceDisplayName(s.voice)) : 'agent';
    const ol = getOverlay();
    ol.textContent = `Drop file to send to ${name}`;
    ol.style.display = 'flex';
  });

  chatArea.addEventListener('dragover', (e) => {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
  });

  chatArea.addEventListener('dragleave', (e) => {
    e.preventDefault();
    dragCounter--;
    if (dragCounter <= 0) {
      dragCounter = 0;
      if (overlay) overlay.style.display = 'none';
    }
  });

  chatArea.addEventListener('drop', async (e) => {
    e.preventDefault();
    dragCounter = 0;
    if (overlay) overlay.style.display = 'none';
    if (!activeSessionId) return;

    const files = e.dataTransfer.files;
    if (!files || files.length === 0) return;

    for (const file of files) {
      if (file.size > 50 * 1024 * 1024) {
        addMessage(activeSessionId, 'system', `File too large: ${file.name} (50MB max)`);
        continue;
      }
      const form = new FormData();
      form.append('file', file);
      try {
        const resp = await fetch(`/api/sessions/${activeSessionId}/upload`, {
          method: 'POST',
          body: form,
        });
        if (!resp.ok) {
          const err = await resp.json().catch(() => ({}));
          addMessage(activeSessionId, 'system', `Upload failed: ${err.error || resp.statusText}`);
        }
      } catch (err) {
        addMessage(activeSessionId, 'system', `Upload error: ${err.message}`);
      }
    }
  });
}
