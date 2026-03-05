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
      };
      actions.appendChild(ackBtn);
    }

    div.appendChild(actions);
  }

  // Double-click to ack messages with an ID (not on user's own messages)
  if (msgObj && msgObj.id && role !== 'system' && role !== 'thinking' && role !== 'user' && role !== 'user interjection') {
    div.addEventListener('dblclick', (e) => {
      e.preventDefault();
      _sendUserAck(msgObj.id);
    });
  }

  return div;
}

function _sendUserAck(msgId) {
  if (!activeSessionId || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ session_id: activeSessionId, type: 'user_ack', msg_id: msgId }));
}

function renderChat(forceScroll = false) {
  // Check if user is near bottom BEFORE clearing DOM (scrollHeight resets after innerHTML='')
  const wasNearBottom = forceScroll || chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
  chatArea.innerHTML = '';
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const vc = voiceColor(s.voice);
  const displayMessages = s.messages.slice(-50);

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

  for (const msg of displayMessages) {
    if (replySet.has(msg)) continue;
    if (!showAgentMessages && msg.role === 'system' && /^\[Agent msg (from|to) /.test(msg.text)) continue;
    const hasThread = msg.id && (threadReplies.has(msg.id) || bareAcks.has(msg.id));
    if (hasThread) {
      const ctr = document.createElement('div');
      ctr.className = 'thread-container';
      const parentEl = createMsgEl(msg.role, msg.text, vc, s.voice, msg);
      const ac = bareAcks.get(msg.id) || 0;
      if (ac > 0) { const b = document.createElement('span'); b.className = 'thread-ack-badge'; b.textContent = ac > 1 ? '\uD83D\uDC4D ' + ac : '\uD83D\uDC4D'; b.title = ac + ' ack'; parentEl.appendChild(b); }
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
      chatArea.appendChild(createMsgEl(msg.role, msg.text, vc, s.voice, msg));
    }
  }
  // Re-show thinking indicator if session is processing
  if (getSessionState(activeSessionId) === 'processing') {
    const div = document.createElement('div');
    div.className = 'msg thinking';
    div.id = `thinking-${activeSessionId}`;
    for (let i = 0; i < 3; i++) {
      const dot = document.createElement('span');
      dot.className = 'thinking-dot';
      div.appendChild(dot);
    }
    const label = document.createElement('span');
    label.className = 'thinking-label';
    label.textContent = s.toolStatusText || '';
    div.appendChild(label);
    chatArea.appendChild(div);
  }
  if (wasNearBottom) chatArea.scrollTop = chatArea.scrollHeight;
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
      chatArea.appendChild(createMsgEl(role, text, voiceColor(s.voice), s.voice, msgObj));
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
  // Move mode toggle and cancel button to left side
  controlsLeft.appendChild(modeToggle);
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

// --- Copy on long-press ---
let longPressTimer = null;
let longPressTarget = null;

function handleMsgPointerDown(e) {
  const msgEl = e.target.closest('.msg');
  if (!msgEl || msgEl.classList.contains('thinking') || msgEl.classList.contains('system')) return;
  longPressTarget = msgEl;
  longPressTimer = setTimeout(() => {
    if (!longPressTarget) return;
    longPressTarget.classList.add('long-press-active');
    const text = longPressTarget.textContent;
    navigator.clipboard.writeText(text).then(() => {
      showCopyToast();
    }).catch(() => {
      // Fallback for older browsers
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      showCopyToast();
    });
    setTimeout(() => {
      if (longPressTarget) longPressTarget.classList.remove('long-press-active');
    }, 200);
    longPressTarget = null;
  }, 500);
}

function handleMsgPointerUp() {
  if (longPressTimer) { clearTimeout(longPressTimer); longPressTimer = null; }
  if (longPressTarget) {
    longPressTarget.classList.remove('long-press-active');
    longPressTarget = null;
  }
}

let copyToastTimer = null;
function showCopyToast(msg) {
  const toast = document.getElementById('copy-toast');
  toast.textContent = msg || 'Copied!';
  toast.classList.add('visible');
  if (copyToastTimer) clearTimeout(copyToastTimer);
  copyToastTimer = setTimeout(() => toast.classList.remove('visible'), 1500);
}

chatArea.addEventListener('pointerdown', handleMsgPointerDown);
chatArea.addEventListener('pointerup', handleMsgPointerUp);
chatArea.addEventListener('pointercancel', handleMsgPointerUp);
chatArea.addEventListener('pointermove', (e) => {
  // Cancel long-press if user moves finger too much
  if (longPressTimer && longPressTarget) {
    longPressTimer && clearTimeout(longPressTimer);
    longPressTimer = null;
    longPressTarget = null;
  }
});

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

