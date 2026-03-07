// ClawMux — Chat Module
// Extracted from hub.html Phase 4 refactor.
// All functions and variables remain global (window-scoped).
//
// Dependencies (defined in state.js and hub.html inline script):
//   state.js: sessions, activeSessionId
//   audio.js: playMessageTTS, stopActiveAudio
//   sidebar.js: voiceColor, voiceDisplayName, renderSidebar,
//               updateLayout, VOICE_NAMES
//   hub.html: chatArea, chatScrollToBottom, controls, textInputBar

// --- Agent message helpers ---
const _AGENT_MSG_RE = /^\[Agent msg (from|to) (\w+)\] ([\s\S]*)$/;

/** Look up a voice color by display name (e.g. "Sky" → "#3A86FF"). */
function _voiceColorByName(name) {
  const lower = name.toLowerCase();
  for (const [id, dname] of Object.entries(VOICE_NAMES)) {
    if (dname.toLowerCase() === lower) return voiceColor(id);
  }
  return '#888';
}

// --- Message Rendering ---
function _renderMarkdown(text) {
  if (typeof marked === 'undefined' || typeof DOMPurify === 'undefined') return null;

  try {
    // Protect math blocks from marked.js processing
    const mathBlocks = [];
    let protectedText = text;
    // Display math $$...$$
    protectedText = protectedText.replace(/\$\$([\s\S]*?)\$\$/g, (m) => {
      mathBlocks.push(m);
      return `MATHBLOCK${mathBlocks.length - 1}ENDMATH`;
    });
    // Inline math $...$
    protectedText = protectedText.replace(/\$([^\$\n]+?)\$/g, (m) => {
      mathBlocks.push(m);
      return `MATHBLOCK${mathBlocks.length - 1}ENDMATH`;
    });

    let html = marked.parse(protectedText, { breaks: true, gfm: true });

    // Restore math blocks
    html = html.replace(/MATHBLOCK(\d+)ENDMATH/g, (_, i) => mathBlocks[parseInt(i)]);

    // Sanitize HTML
    html = DOMPurify.sanitize(html, {
      ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'code', 'pre', 'ul', 'ol', 'li',
        'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'a', 'blockquote', 'table', 'thead',
        'tbody', 'tr', 'th', 'td', 'hr', 'img', 'span', 'div', 'del', 'sup', 'sub'],
      ALLOWED_ATTR: ['href', 'src', 'alt', 'class', 'style', 'target'],
    });

    // Create container
    const container = document.createElement('div');
    container.className = 'md-content';
    container.innerHTML = html;

    // Syntax-highlight code blocks with highlight.js
    if (typeof hljs !== 'undefined') {
      container.querySelectorAll('pre code').forEach(block => {
        hljs.highlightElement(block);
      });
    }

    // Make links open in new tab
    container.querySelectorAll('a').forEach(a => { a.target = '_blank'; a.rel = 'noopener'; });

    // Add copy button to code blocks
    container.querySelectorAll('pre').forEach(pre => {
      const btn = document.createElement('button');
      btn.className = 'code-copy-btn';
      btn.textContent = 'Copy';
      btn.onclick = (e) => {
        e.stopPropagation();
        const code = pre.querySelector('code');
        const text = code ? code.textContent : pre.textContent;
        navigator.clipboard.writeText(text).then(() => {
          btn.textContent = 'Copied!';
          setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
        }).catch(() => { btn.textContent = 'Error'; setTimeout(() => { btn.textContent = 'Copy'; }, 1500); });
      };
      pre.appendChild(btn);
    });

    // Click-to-copy for inline code
    container.querySelectorAll('code:not(pre code)').forEach(code => {
      code.onclick = (e) => {
        e.stopPropagation();
        navigator.clipboard.writeText(code.textContent).then(() => {
          if (typeof showCopyToast === 'function') showCopyToast();
        });
      };
    });

    // Render KaTeX math ($$...$$ and $...$)
    if (typeof renderMathInElement === 'function') {
      renderMathInElement(container, {
        delimiters: [
          { left: '$$', right: '$$', display: true },
          { left: '$', right: '$', display: false },
          { left: '\\[', right: '\\]', display: true },
          { left: '\\(', right: '\\)', display: false },
        ],
        throwOnError: false,
      });
    }

    // Wrap text nodes in karaoke-word spans for TTS highlighting compatibility
    _wrapTextNodesInKaraokeSpans(container);

    return container;
  } catch (e) {
    console.warn('Markdown render error:', e);
    return null;
  }
}

function createMsgEl(role, text, voiceColorHex, voiceId, msgObj = null) {
  const div = document.createElement('div');
  div.className = `msg ${role}`;
  if (msgObj && msgObj.id) div.dataset.msgId = msgObj.id;

  // --- Inter-agent messages: collapsed one-liner with click-to-expand ---
  const agentMatch = (role === 'system') ? _AGENT_MSG_RE.exec(text) : null;
  if (agentMatch) {
    const [, direction, agentName, content] = agentMatch;
    const color = _voiceColorByName(agentName);
    div.className = 'msg agent-msg';
    div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';

    // One-liner header: "→ Sky" or "← Echo"
    const arrow = direction === 'from' ? '\u2190' : '\u2192';
    const header = document.createElement('span');
    header.className = 'agent-msg-header';
    const nameSpan = document.createElement('span');
    nameSpan.style.cssText = `color:${color};font-weight:600`;
    nameSpan.textContent = `${arrow} ${agentName}`;
    header.appendChild(nameSpan);

    // Expandable body
    const body = document.createElement('div');
    body.className = 'agent-msg-body';
    body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;';
    const mdEl = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
    if (mdEl) body.appendChild(mdEl);
    else body.textContent = content;

    div.appendChild(header);
    div.appendChild(body);

    div.addEventListener('click', (e) => {
      if (e.target.closest('.msg-actions')) return;
      const showing = body.style.display !== 'none';
      body.style.display = showing ? 'none' : 'block';
      div.style.opacity = showing ? '0.7' : '1';
    });

    if (voiceId) div.dataset.voice = voiceId;
    if (text) div.dataset.text = text;
    return div;
  }

  if (role === 'assistant') {
    // Try markdown rendering first, fall back to karaoke word wrapping
    const mdEl = (typeof marked !== 'undefined') ? _renderMarkdown(text) : null;
    if (mdEl) {
      div.appendChild(mdEl);
    } else {
      _wrapWordsInSpans(div, text);
    }
  } else {
    div.textContent = text;
  }
  if (voiceId) div.dataset.voice = voiceId;
  if (text) div.dataset.text = text;
  if (role === 'assistant' && voiceColorHex) div.style.background = hexToRgba(voiceColorHex, 0.20);
  if (role !== 'system' && role !== 'thinking') {
    const actions = document.createElement('div');
    actions.className = 'msg-actions';

    // Copy button
    const copyBtn = document.createElement('button');
    copyBtn.className = 'msg-action-btn';
    copyBtn.textContent = 'Copy';
    copyBtn.onclick = (e) => {
      e.stopPropagation();
      navigator.clipboard.writeText(text).then(() => showCopyToast()).catch(() => {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.cssText = 'position:fixed;opacity:0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        showCopyToast();
      });
    };
    actions.appendChild(copyBtn);

    // Thumbs-up (ack) button — only on non-user messages with an ID
    if (msgObj && msgObj.id && role !== 'user' && role !== 'user interjection') {
      const ackBtn = document.createElement('button');
      ackBtn.className = 'msg-action-btn msg-ack-btn';
      ackBtn.textContent = '\uD83D\uDC4D';
      ackBtn.title = 'Acknowledge';
      ackBtn.onclick = (e) => {
        e.stopPropagation();
        _sendUserAck(msgObj.id);
        ackBtn.classList.add('acked');
        ackBtn.textContent = '\u2705';
      };
      actions.appendChild(ackBtn);
    }

    div.appendChild(actions);
  }

  // Mobile: attach long-press directly to each message (matches sidebar pattern)
  if (isMobile && role !== 'thinking' && role !== 'system') {
    let lpTimer = null, lpFired = false, startX = 0, startY = 0;
    div.oncontextmenu = (e) => e.preventDefault();
    div.addEventListener('touchstart', (e) => {
      lpFired = false;
      const touch = e.touches[0];
      startX = touch.clientX; startY = touch.clientY;
      lpTimer = setTimeout(() => {
        lpTimer = null; lpFired = true;
        _longPressFired = true;
        div.classList.add('long-press-active');
        // Programmatically clear any native text selection
        const sel = window.getSelection();
        if (sel) sel.removeAllRanges();
        _showContextMenu(div, touch.clientX, touch.clientY);
        setTimeout(() => div.classList.remove('long-press-active'), 200);
      }, 400);
    }, { passive: false });
    div.addEventListener('touchend', (e) => {
      if (lpTimer) { clearTimeout(lpTimer); lpTimer = null; }
      if (lpFired) { e.preventDefault(); lpFired = false; }
    });
    div.addEventListener('touchmove', (e) => {
      if (lpTimer) {
        const t = e.touches[0];
        if (Math.abs(t.clientX - startX) > 10 || Math.abs(t.clientY - startY) > 10) {
          clearTimeout(lpTimer); lpTimer = null;
        }
      }
    }, { passive: true });
  }

  return div;
}

function _sendUserAck(msgId) {
  if (!activeSessionId || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ session_id: activeSessionId, type: 'user_ack', msg_id: msgId }));
}

const _CHAT_BATCH = 50;
const _CHAT_MAX_DOM = 150; // max messages in DOM — triggers unload when exceeded
const _chatRenderLimit = new Map(); // session_id → max messages to display

function _getChatLimit(sid) {
  return _chatRenderLimit.get(sid) || _CHAT_BATCH;
}

function renderChat(forceScroll = false) {
  // Check if user is near bottom BEFORE clearing DOM (scrollHeight resets after innerHTML='')
  const wasNearBottom = forceScroll || chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
  chatArea.innerHTML = '';
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const vc = voiceColor(s.voice);
  const limit = _getChatLimit(activeSessionId);
  const displayMessages = s.messages.slice(-limit);

  // Build thread index
  const threadReplies = new Map();
  const bareAcks = new Map();
  const replySet = new Set();
  for (const m of displayMessages) {
    if (m.parentId) {
      replySet.add(m);
      if (m.isBareAck) bareAcks.set(m.parentId, (bareAcks.get(m.parentId) || 0) + 1);
      else { if (!threadReplies.has(m.parentId)) threadReplies.set(m.parentId, []); threadReplies.get(m.parentId).push(m); }
    }
  }

  // Show "load more" indicator if there are older messages
  const hasMore = s.messages.length > limit;
  if (hasMore) {
    const loader = document.createElement('div');
    loader.id = 'chat-load-more';
    loader.style.cssText = 'text-align:center;padding:8px;font-size:0.8em;color:var(--text-tertiary,#666);cursor:pointer;';
    loader.textContent = '\u25B2 Load older messages';
    loader.onclick = () => _loadMoreMessages();
    chatArea.appendChild(loader);
  }

  for (const msg of displayMessages) {
    if (replySet.has(msg)) continue;
    if (msg.role === 'activity') {
      const line = document.createElement('div');
      line.className = 'activity-line';
      line.textContent = msg.text;
      chatArea.appendChild(line);
      continue;
    }
    if (!showAgentMessages && msg.role === 'system' && /^\[Agent msg (from|to) /.test(msg.text)) continue;
    const hasReplies = msg.id && threadReplies.has(msg.id);
    const hasAcksOnly = msg.id && !hasReplies && bareAcks.has(msg.id);
    if (hasReplies) {
      const ctr = document.createElement('div');
      ctr.className = 'thread-container';
      const parentEl = createMsgEl(msg.role, msg.text, vc, s.voice, msg);
      const ac = bareAcks.get(msg.id) || 0;
      if (ac > 0) {
        const b = document.createElement('span'); b.className = 'thread-ack-badge'; b.textContent = ac > 1 ? '\uD83D\uDC4D ' + ac : '\uD83D\uDC4D'; b.title = ac + ' ack'; parentEl.appendChild(b);
        // Hide the ack button since badge is showing
        const ackBtn = parentEl.querySelector('.msg-ack-btn');
        if (ackBtn) ackBtn.style.display = 'none';
      }
      ctr.appendChild(parentEl);
      const reps = threadReplies.get(msg.id) || [];
      const collapse = reps.length >= 3;
      const hidden = [];
      for (let i = 0; i < reps.length; i++) {
        const r = reps[i];
        if (!showAgentMessages && r.role === 'system' && /^\[Agent msg (from|to) /.test(r.text)) continue;
        const el = createMsgEl(r.role, r.text, vc, s.voice, r);
        el.classList.add('thread-reply');
        if (collapse && i > 0 && i < reps.length - 1) { el.style.display = 'none'; hidden.push(el); }
        ctr.appendChild(el);
      }
      if (collapse && hidden.length > 0) {
        const tog = document.createElement('button');
        tog.className = 'thread-toggle';
        tog.textContent = 'Show ' + hidden.length + ' more';
        tog.onclick = () => { const exp = hidden[0].style.display === 'none'; hidden.forEach(e => e.style.display = exp ? '' : 'none'); tog.textContent = exp ? 'Collapse' : 'Show ' + hidden.length + ' more'; };
        const fr = ctr.querySelector('.thread-reply');
        if (fr && fr.nextSibling) ctr.insertBefore(tog, fr.nextSibling); else ctr.appendChild(tog);
      }
      chatArea.appendChild(ctr);
    } else {
      const el = createMsgEl(msg.role, msg.text, vc, s.voice, msg);
      if (hasAcksOnly) {
        const ac = bareAcks.get(msg.id) || 0;
        const b = document.createElement('span'); b.className = 'thread-ack-badge'; b.textContent = ac > 1 ? '\uD83D\uDC4D ' + ac : '\uD83D\uDC4D'; b.title = ac + ' ack'; el.appendChild(b);
        const ackBtn = el.querySelector('.msg-ack-btn');
        if (ackBtn) ackBtn.style.display = 'none';
      }
      chatArea.appendChild(el);
    }
  }
  if (wasNearBottom) chatArea.scrollTop = chatArea.scrollHeight;
}

function _loadMoreMessages() {
  if (!activeSessionId) return;
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const currentLimit = _getChatLimit(activeSessionId);
  if (currentLimit >= s.messages.length) return; // all loaded
  // Save scroll position relative to content height
  const oldHeight = chatArea.scrollHeight;
  _chatRenderLimit.set(activeSessionId, currentLimit + _CHAT_BATCH);
  renderChat();
  // Restore scroll position — keep user at the same content
  const newHeight = chatArea.scrollHeight;
  chatArea.scrollTop = newHeight - oldHeight;
}

// Scroll-to-top listener for lazy loading + scroll-to-bottom unloading
let _scrollLoadPending = false;
function _initChatScroll() {
  chatArea.addEventListener('scroll', () => {
    if (_scrollLoadPending) return;
    // Load more when scrolling near top
    if (chatArea.scrollTop < 100 && activeSessionId) {
      const s = sessions.get(activeSessionId);
      const limit = _getChatLimit(activeSessionId);
      if (s && s.messages.length > limit) {
        _scrollLoadPending = true;
        requestAnimationFrame(() => {
          _loadMoreMessages();
          _scrollLoadPending = false;
        });
      }
    }
    // Unload old messages when scrolling back to bottom
    if (activeSessionId) {
      const limit = _getChatLimit(activeSessionId);
      const nearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
      if (nearBottom && limit > _CHAT_MAX_DOM) {
        _scrollLoadPending = true;
        requestAnimationFrame(() => {
          _chatRenderLimit.set(activeSessionId, _CHAT_BATCH);
          renderChat();
          chatArea.scrollTop = chatArea.scrollHeight;
          _scrollLoadPending = false;
        });
      }
    }
  });
}

function _debugBanner(msg) { /* no-op */ }

function addMessage(sessionId, role, text, opts = {}) {
  const s = sessions.get(sessionId);
  if (!s) return;
  const msgObj = { role, text, ts: Date.now() / 1000 };
  if (opts.id) msgObj.id = opts.id;
  if (opts.parentId) msgObj.parentId = opts.parentId;
  if (opts.isBareAck) msgObj.isBareAck = true;
  s.messages.push(msgObj);
  if (sessionId === activeSessionId) {
    // For threaded messages, re-render to group properly
    if (opts.parentId) {
      renderChat();
    } else {
      const wasNearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
      let el;
      if (role === 'activity') {
        el = document.createElement('div');
        el.className = 'activity-line';
        el.textContent = text;
      } else {
        el = createMsgEl(role, text, voiceColor(s.voice), s.voice, msgObj);
      }
      chatArea.appendChild(el);
      if (wasNearBottom) chatArea.scrollTop = chatArea.scrollHeight;
    }
  }
}

// --- Input Mode & Text Input ---
// --- Input mode (Auto / Typing) ---
let inputMode = 'voice'; // 'voice' or 'typing'
const modeToggle = document.getElementById('mode-toggle');
const modeToggleText = document.getElementById('mode-toggle-text');
// Rearrange controls: top row = waveform/transport, bottom row = mode | mic | status
{
  const controlsEl = document.getElementById('controls');
  const controlsLeft = document.getElementById('controls-left');
  const controlsRight = document.getElementById('controls-right');
  // Move status to the right side
  controlsRight.appendChild(document.getElementById('status'));
  // Move cancel button to left side (mode toggle is now in header)
  controlsLeft.appendChild(document.getElementById('mic-cancel'));
  // Create a top row for waveform
  const topRow = document.createElement('div');
  topRow.id = 'controls-top';
  const waveform = document.getElementById('waveform');
  topRow.appendChild(waveform);
  controlsEl.insertBefore(topRow, controlsEl.firstChild);
}
// textInputBar declared in DOM refs block above
const textInput = document.getElementById('text-input');
const textSendBtn = document.getElementById('text-send');

function cycleInputMode() {
  // Block switching to voice when text-only mode is enabled
  const textOnlyToggle = document.getElementById('toggle-text_only');
  if (textOnlyToggle && textOnlyToggle.classList.contains('on')) return;
  inputMode = inputMode === 'voice' ? 'typing' : 'voice';
  applyInputMode();
  saveInputMode();
  // Tell hub about mode change
  if (ws && ws.readyState === WebSocket.OPEN && activeSessionId) {
    ws.send(JSON.stringify({ session_id: activeSessionId, type: 'set_mode', mode: inputMode === 'typing' ? 'text' : 'voice' }));
  }
}

function applyInputMode() {
  const modeText = inputMode === 'voice' ? 'Voice' : 'Typing';
  modeToggle.innerHTML = '<span class="mode-value">' + modeText + '</span><span class="mode-label">Mode</span>';
  // Also update text-input-bar mode toggle
  if (modeToggleText) modeToggleText.querySelector('.mode-value').textContent = modeText;
  if (inputMode === 'typing') {
    controls.style.display = 'none';
    textInputBar.classList.add('active');
    textInput.focus();
    requestAnimationFrame(() => { chatScrollToBottom(true); });
  } else {
    textInputBar.classList.remove('active');
    if (activeSessionId && sessions.has(activeSessionId)) {
      controls.style.display = 'grid';
    }
  }
}

// Auto-resize textarea
textInput.addEventListener('input', () => {
  textInput.style.height = 'auto';
  textInput.style.height = Math.min(textInput.scrollHeight, 120) + 'px';
  textSendBtn.disabled = !textInput.value.trim();
});

// Send on Enter (Shift+Enter for newline)
textInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendTextMessage();
  }
});

function sendTextMessage() {
  const text = textInput.value.trim();
  if (!text || !ws || ws.readyState !== WebSocket.OPEN || !activeSessionId) return;
  // Check if agent is NOT awaiting input — send as interjection
  const s = sessions.get(activeSessionId);
  const isInterjection = s && s.sessionState !== 'listening';
  const msgType = isInterjection ? 'interjection' : 'text';
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
      _sendUserAck(msgId);
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

