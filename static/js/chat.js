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
const _GROUP_MSG_RE = /^\[Group msg to ([^\]]+)\] ([\s\S]*)$/;

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

    // Add language label + copy button to code blocks
    container.querySelectorAll('pre').forEach(pre => {
      const code = pre.querySelector('code');
      // Language label from hljs class e.g. "language-python" → "python"
      if (code) {
        const langClass = Array.from(code.classList).find(c => c.startsWith('language-'));
        if (langClass) {
          const lang = langClass.replace('language-', '');
          const label = document.createElement('span');
          label.className = 'code-lang-label';
          label.textContent = lang;
          pre.appendChild(label);
        }
      }
      const btn = document.createElement('button');
      btn.className = 'code-copy-btn';
      btn.textContent = 'Copy';
      btn.onclick = (e) => {
        e.stopPropagation();
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

    // Lazy-load images — replace <img> with click-to-reveal placeholder
    container.querySelectorAll('img').forEach(img => {
      const src = img.getAttribute('src') || '';
      const alt = img.alt || 'image';
      const wrap = document.createElement('div');
      wrap.className = 'chat-img-placeholder';
      const icon = document.createElement('span');
      icon.className = 'chat-img-icon';
      icon.textContent = '🖼';
      const label = document.createElement('span');
      label.className = 'chat-img-label';
      label.textContent = alt;
      const hint = document.createElement('span');
      hint.className = 'chat-img-hint';
      hint.textContent = 'click to load';
      wrap.append(icon, label, hint);
      wrap.onclick = () => {
        const actualImg = document.createElement('img');
        actualImg.src = src;
        actualImg.alt = alt;
        actualImg.className = 'chat-img-revealed';
        wrap.replaceWith(actualImg);
      };
      img.replaceWith(wrap);
    });

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
    const mdEl = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
    if (mdEl) {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;';
      body.appendChild(mdEl);
    } else {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;';
      body.textContent = content;
    }

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

  // --- Group chat outbound messages: same collapsed style ---
  const groupMatch = (role === 'system') ? _GROUP_MSG_RE.exec(text) : null;
  if (groupMatch) {
    const [, groupName, content] = groupMatch;
    div.className = 'msg agent-msg';
    div.style.cssText = 'padding:3px 10px;margin:2px 0;font-size:0.82em;opacity:0.7;cursor:pointer;';

    const header = document.createElement('span');
    header.className = 'agent-msg-header';
    const nameSpan = document.createElement('span');
    nameSpan.style.cssText = 'color:#7c9ef0;font-weight:600';
    nameSpan.textContent = `\u2295 ${groupName}`;
    header.appendChild(nameSpan);

    const body = document.createElement('div');
    body.className = 'agent-msg-body';
    const mdEl2 = (typeof marked !== 'undefined') ? _renderMarkdown(content) : null;
    if (mdEl2) {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;';
      body.appendChild(mdEl2);
    } else {
      body.style.cssText = 'display:none;margin-top:4px;opacity:0.9;font-size:0.95em;white-space:pre-wrap;';
      body.textContent = content;
    }

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
  // Timestamp label (hover to reveal)
  if (role === 'user' || role === 'assistant' || role === 'user interjection') {
    const ts = msgObj && msgObj.ts ? msgObj.ts : Date.now() / 1000;
    const tsEl = document.createElement('span');
    tsEl.className = 'msg-ts';
    tsEl.textContent = new Date(ts * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    div.appendChild(tsEl);
  }
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
        div.dataset.selfAcked = '1'; // flag to absorb server echo
        // Store immediately so renderChat shows badge if called before server echo
        const _s = sessions.get(activeSessionId);
        if (_s) _s.messages.push({ role: 'system', text: '', ts: Date.now() / 1000, id: 'local-ack-' + msgObj.id, parentId: msgObj.id, isBareAck: true });
        _showPermanentAck(div, 1);
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

function _showPermanentAck(msgEl, count) {
  let badge = msgEl.querySelector('.msg-ack-permanent');
  if (badge) {
    badge.textContent = count > 1 ? '\uD83D\uDC4D ' + count : '\uD83D\uDC4D';
    badge.title = count + ' ack';
  } else {
    badge = document.createElement('span');
    badge.className = 'msg-ack-permanent';
    badge.textContent = '\uD83D\uDC4D';
    badge.title = '1 ack';
    // For agent messages, place badge inline inside the header (right next to arrow+name)
    if (msgEl.classList.contains('agent-msg')) {
      const header = msgEl.querySelector('.agent-msg-header');
      (header || msgEl).appendChild(badge);
    } else {
      msgEl.appendChild(badge);
    }
    // Make ack button invisible but keep it in flow so copy button doesn't shift position
    const ackBtn = msgEl.querySelector('.msg-ack-btn');
    if (ackBtn) { ackBtn.style.opacity = '0'; ackBtn.style.pointerEvents = 'none'; ackBtn.style.cursor = 'default'; }
  }
  badge.dataset.count = count || 1;
}

function _sendUserAck(msgId) {
  if (!activeSessionId || !ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ session_id: activeSessionId, type: 'user_ack', msg_id: msgId }));
}

const _CHAT_BATCH = 50;
const _chatRenderLimit = new Map(); // session_id → visible message limit

function _getChatLimit(sid) {
  return _chatRenderLimit.get(sid) || _CHAT_BATCH;
}

// Walk backwards through messages counting only *visible* ones.
// Returns { slice, hasMore } where slice is the messages to render and
// hasMore indicates there are visible messages before the slice.
// "Visible" = not a reply/ack, not activity (in minimal mode), not filtered agent msg.
function _getDisplaySlice(messages, visibleLimit) {
  let visibleCount = 0;
  let sliceStart = 0;
  let limitReached = false;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    const isVisible = !m.parentId &&
      m.role !== 'activity' &&
      (showAgentMessages || !(m.role === 'system' && /^\[(Agent msg (from|to)|Group msg to) /.test(m.text)));
    if (isVisible) {
      visibleCount++;
      if (visibleCount === visibleLimit && !limitReached) {
        sliceStart = i;
        limitReached = true;
        // Keep scanning to count total visible (determines hasMore)
      }
    }
  }
  if (limitReached) {
    return { slice: messages.slice(sliceStart), hasMore: visibleCount > visibleLimit };
  }
  // Fewer visible messages than the limit — show everything, no load-more button needed
  return { slice: messages, hasMore: false };
}

// --- Activity line grouping ---
// Groups consecutive activity lines into a collapsible dropdown.
// First activity shows as a standalone line. Second+ collapse into a group.
function _appendActivityLine(container, text) {
  const lastChild = container.lastElementChild;

  // Case 1: Last child is an activity-group — add to it
  if (lastChild && lastChild.classList.contains('activity-group')) {
    const items = lastChild.querySelector('.activity-group-items');
    const line = document.createElement('div');
    line.className = 'activity-line';
    line.textContent = text;
    items.appendChild(line);
    // Update header to show latest tool call
    const label = lastChild.querySelector('.activity-group-label');
    label.textContent = text;
    const count = lastChild.querySelector('.activity-group-count');
    const total = items.children.length + 1; // +1 for the first line stored in data
    count.textContent = '+' + (total - 1) + ' more';
    return;
  }

  // Case 2: Last child is a standalone activity-line — convert to group
  if (lastChild && lastChild.classList.contains('activity-line')) {
    const firstText = lastChild.textContent;
    const group = document.createElement('div');
    group.className = 'activity-group';
    const header = document.createElement('div');
    header.className = 'activity-group-header';
    header.onclick = () => group.classList.toggle('expanded');
    const arrow = document.createElement('span');
    arrow.className = 'activity-group-arrow';
    arrow.textContent = '\u25B6';
    const label = document.createElement('span');
    label.className = 'activity-group-label';
    label.textContent = text;
    const countEl = document.createElement('span');
    countEl.className = 'activity-group-count';
    countEl.textContent = '+1 more';
    header.appendChild(arrow);
    header.appendChild(label);
    header.appendChild(countEl);
    const items = document.createElement('div');
    items.className = 'activity-group-items';
    // First line goes into the hidden items
    const firstLine = document.createElement('div');
    firstLine.className = 'activity-line';
    firstLine.textContent = firstText;
    items.appendChild(firstLine);
    group.appendChild(header);
    group.appendChild(items);
    container.replaceChild(group, lastChild);
    return;
  }

  // Case 3: No previous activity — add standalone line
  const line = document.createElement('div');
  line.className = 'activity-line';
  line.textContent = text;
  container.appendChild(line);
}

function renderChat(forceScroll = false) {
  // Check if user is near bottom BEFORE clearing DOM (scrollHeight resets after innerHTML='')
  const wasNearBottom = forceScroll || chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
  chatArea.innerHTML = '';
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const vc = voiceColor(s.voice);
  const limit = _getChatLimit(activeSessionId);
  const { slice: displayMessages, hasMore } = _getDisplaySlice(s.messages, limit);

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

  // Show "load more" indicator if there are older visible messages
  if (hasMore) {
    const loader = document.createElement('div');
    loader.id = 'chat-load-more';
    loader.style.cssText = 'text-align:center;padding:8px;font-size:0.8em;color:var(--text-tertiary,#666);cursor:pointer;touch-action:manipulation;';
    loader.textContent = '\u25B2 Load older messages';
    loader.onclick = () => _loadMoreMessages();
    chatArea.appendChild(loader);
  }

  for (const msg of displayMessages) {
    if (replySet.has(msg)) continue;
    if (msg.role === 'activity') {
      if (typeof activityVerbose !== 'undefined' && activityVerbose) {
        _appendActivityLine(chatArea, msg.text);
      }
      // In minimal mode: skip activity from history entirely
      continue;
    }
    if (!showAgentMessages && msg.role === 'system' && /^\[(Agent msg (from|to)|Group msg to) /.test(msg.text)) continue;
    const hasReplies = msg.id && threadReplies.has(msg.id);
    const hasAcksOnly = msg.id && !hasReplies && bareAcks.has(msg.id);
    if (hasReplies) {
      const ctr = document.createElement('div');
      ctr.className = 'thread-container';
      const parentEl = createMsgEl(msg.role, msg.text, vc, s.voice, msg);
      const ac = bareAcks.get(msg.id) || 0;
      if (ac > 0) _showPermanentAck(parentEl, ac);
      ctr.appendChild(parentEl);
      const reps = threadReplies.get(msg.id) || [];
      const collapse = reps.length >= 3;
      const hidden = [];
      for (let i = 0; i < reps.length; i++) {
        const r = reps[i];
        if (!showAgentMessages && r.role === 'system' && /^\[(Agent msg (from|to)|Group msg to) /.test(r.text)) continue;
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
        if (ac > 0) _showPermanentAck(el, ac);
      }
      chatArea.appendChild(el);
    }
  }
  if (wasNearBottom) chatArea.scrollTop = chatArea.scrollHeight;
  // Mark all bulk-rendered messages as already-rendered so they don't animate
  chatArea.querySelectorAll('.msg').forEach(el => el.classList.add('rendered'));
  // Restore typing indicator if session is currently active (e.g. switching back to a busy tab)
  if (s && s.sessionState === 'processing' && typeof showTypingIndicator === 'function') {
    showTypingIndicator(activeSessionId);
  }
}

function _loadMoreMessages() {
  if (!activeSessionId) return;
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const limit = _getChatLimit(activeSessionId);
  // Cancel any in-progress eased scroll — its scroll events would re-trigger load-more
  if (typeof _scrollRaf !== 'undefined' && _scrollRaf) {
    cancelAnimationFrame(_scrollRaf);
    _scrollRaf = null;
  }
  // If there are more locally buffered visible messages, expand the render window first
  if (_getDisplaySlice(s.messages, limit).hasMore) {
    const oldHeight = chatArea.scrollHeight;
    _chatRenderLimit.set(activeSessionId, limit + _CHAT_BATCH);
    _scrollLoadPending = true;
    renderChat(); // single render, no forceScroll
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        chatArea.scrollTop = chatArea.scrollHeight - oldHeight;
        requestAnimationFrame(() => { _scrollLoadPending = false; });
      });
    });
    return;
  }
  // Local messages exhausted — fetch older page from server if available
  if (s.hasMoreHistory && !s.loadingOlderHistory) {
    _fetchOlderHistory(activeSessionId);
  }
}

async function _fetchOlderHistory(sessionId) {
  const s = sessions.get(sessionId);
  if (!s || s.loadingOlderHistory || !s.hasMoreHistory) return;
  s.loadingOlderHistory = true;

  // Show subtle loading indicator at top of chat
  let loadingEl = chatArea.querySelector('#history-loading-indicator');
  if (!loadingEl) {
    loadingEl = document.createElement('div');
    loadingEl.id = 'history-loading-indicator';
    loadingEl.style.cssText = 'text-align:center;padding:6px;font-size:0.78em;color:var(--text-tertiary,#666);opacity:0.7;';
    loadingEl.textContent = 'Loading older messages\u2026';
    chatArea.insertBefore(loadingEl, chatArea.firstChild);
  }

  // Find the oldest message ID in s.messages to use as the before= cursor
  let oldestId = null;
  for (let i = 0; i < s.messages.length; i++) {
    if (s.messages[i].id) { oldestId = s.messages[i].id; break; }
  }

  try {
    const project = typeof currentProject !== 'undefined' ? currentProject : '';
    const url = `/api/history/${s.voice}?limit=150${oldestId ? '&before=' + encodeURIComponent(oldestId) : ''}${project ? '&project=' + encodeURIComponent(project) : ''}`;
    const resp = await fetch(url);
    if (!resp.ok) throw new Error('fetch failed: ' + resp.status);
    const hist = await resp.json();
    s.hasMoreHistory = hist.has_more === true;
    const olderMsgs = (hist.messages || []).map(m => {
      const obj = { role: m.role, text: m.text };
      if (m.id) obj.id = m.id;
      if (m.ts) obj.ts = m.ts;
      if (m.parent_id) obj.parentId = m.parent_id;
      if (m.bare_ack) obj.isBareAck = true;
      return obj;
    });
    if (olderMsgs.length > 0) {
      // Deduplicate: skip any IDs already in s.messages
      const existingIds = new Set(s.messages.filter(m => m.id).map(m => m.id));
      const newMsgs = olderMsgs.filter(m => !m.id || !existingIds.has(m.id));
      if (newMsgs.length > 0) {
        // Prepend to s.messages and expand render limit to include them
        s.messages.unshift(...newMsgs);
        const newLimit = (_getChatLimit(sessionId) || _CHAT_BATCH) + newMsgs.length;
        _chatRenderLimit.set(sessionId, newLimit);
        if (sessionId === activeSessionId) {
          const oldHeight = chatArea.scrollHeight;
          // Remove loading indicator before re-render
          if (loadingEl && loadingEl.parentNode) loadingEl.remove();
          _scrollLoadPending = true;
          renderChat();
          requestAnimationFrame(() => {
            requestAnimationFrame(() => {
              chatArea.scrollTop = chatArea.scrollHeight - oldHeight;
              requestAnimationFrame(() => { _scrollLoadPending = false; });
            });
          });
        }
      }
    }
  } catch (e) {
    console.warn('[history pagination] fetch older failed:', e);
  } finally {
    s.loadingOlderHistory = false;
    const indicator = chatArea.querySelector('#history-loading-indicator');
    if (indicator) indicator.remove();
  }
}

// Fill the viewport on tab switch. With visible-limit semantics, _CHAT_BATCH (50) visible
// messages should always fill any mobile screen. This is a light fallback for sessions
// with very few real messages total (e.g. 1-3 messages — they're all shown, nothing to fill).
function _fillViewportMessages() {
  if (!activeSessionId) return;
  const s = sessions.get(activeSessionId);
  if (!s) return;
  if (chatArea.scrollHeight > chatArea.clientHeight + 10) return; // already filled
  const limit = _getChatLimit(activeSessionId);
  if (!_getDisplaySlice(s.messages, limit).hasMore) return; // nothing more to load
  // Load one more batch of visible messages
  _chatRenderLimit.set(activeSessionId, limit + _CHAT_BATCH);
  _scrollLoadPending = true;
  renderChat(true);
  requestAnimationFrame(() => { _scrollLoadPending = false; });
}

// Scroll-to-top listener for lazy loading + scroll-to-bottom unloading
let _scrollLoadPending = false;
const _scrollBottomBtn = document.getElementById('scroll-bottom-btn');
function _updateScrollBottomBtn() {
  if (!_scrollBottomBtn) return;
  const nearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 200;
  _scrollBottomBtn.classList.toggle('visible', !nearBottom);
}
function _initChatScroll() {
  chatArea.addEventListener('scroll', () => {
    _updateScrollBottomBtn();
    if (_scrollLoadPending) return;
    // Load more when scrolling near top (local buffer or server pagination)
    // Guard: skip if viewport is too small to be meaningfully scrollable
    // (prevents infinite load loop when scrollHeight ≈ clientHeight)
    if (chatArea.scrollTop < 100 && activeSessionId && chatArea.scrollHeight > chatArea.clientHeight + 150) {
      const s = sessions.get(activeSessionId);
      const limit = _getChatLimit(activeSessionId);
      if (s) {
        const { hasMore: localHasMore } = _getDisplaySlice(s.messages, limit);
        if (localHasMore) {
          // Expand render window from local buffer
          _scrollLoadPending = true;
          requestAnimationFrame(() => {
            _loadMoreMessages();
            _scrollLoadPending = false;
          });
        } else if (s.hasMoreHistory && !s.loadingOlderHistory) {
          // Local buffer exhausted — fetch older page from server
          _fetchOlderHistory(activeSessionId);
        }
      }
    }
    // (Unload removed — resetting DOM on scroll-to-bottom caused messages to disappear
    //  for sparse sessions that needed large limits to show visible content.)
  });
}

function _debugBanner(msg) { /* no-op */ }

function addMessage(sessionId, role, text, opts = {}) {
  const s = sessions.get(sessionId);
  if (!s) return;
  // Dedup: skip if a message with the same ID already exists in the store
  if (opts.id && s.messages.some(m => m.id === opts.id)) return;
  const msgObj = { role, text, ts: opts.ts || Date.now() / 1000 };
  if (opts.id) msgObj.id = opts.id;
  if (opts.parentId) msgObj.parentId = opts.parentId;
  if (opts.isBareAck) msgObj.isBareAck = true;
  s.messages.push(msgObj);
  if (sessionId === activeSessionId) {
    // For threaded messages, insert inline under the parent
    if (opts.parentId) {
      const wasNearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
      const vc = voiceColor(s.voice);
      const parentEl = chatArea.querySelector(`[data-msg-id="${CSS.escape(opts.parentId)}"]`);
      if (parentEl) {
        if (opts.isBareAck) {
          // Bare ack: transform the ack button in-place — no separate badge element
          // This avoids overlap since the button is already in .msg-actions at the right position
          if (parentEl.dataset.selfAcked) {
            // Server echo of user's own click — absorb the count increment but ensure badge is visible
            delete parentEl.dataset.selfAcked;
          }
          // Always (re)apply badge — renderChat may have wiped a DOM-only badge
          const existing = parentEl.querySelector('.msg-ack-permanent');
          const count = existing ? parseInt(existing.dataset.count || '1') : 1;
          _showPermanentAck(parentEl, count);
        } else {
          // Threaded reply: find or create thread container
          let threadCtr = parentEl.closest('.thread-container');
          if (!threadCtr) {
            threadCtr = document.createElement('div');
            threadCtr.className = 'thread-container';
            parentEl.before(threadCtr);
            threadCtr.appendChild(parentEl);
          }
          const replyEl = createMsgEl(role, text, vc, s.voice, msgObj);
          replyEl.classList.add('thread-reply');
          threadCtr.appendChild(replyEl);
        }
      } else if (!opts.isBareAck) {
        // Parent not in DOM — append at bottom as a normal message (skip for bare acks)
        const el = createMsgEl(role, text, vc, s.voice, msgObj);
        chatArea.appendChild(el);
      }
      if (wasNearBottom) chatScrollToBottom(true);
    } else {
      const wasNearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 150;
      let el;
      if (role === 'activity') {
        if (typeof activityVerbose !== 'undefined' && activityVerbose) {
          _appendActivityLine(chatArea, text);
        } else {
          // Minimal mode: update/create typing indicator with activity text
          _updateTypingIndicatorText(sessionId, text);
        }
      } else {
        // Auto-collapse any open activity group when a real message arrives
        const lastGroup = chatArea.querySelector('.activity-group.expanded');
        if (lastGroup) lastGroup.classList.remove('expanded');
        el = createMsgEl(role, text, voiceColor(s.voice), s.voice, msgObj);
        // Append message BEFORE fading out indicator — net height stays positive so no scroll clamp
        chatArea.appendChild(el);
        if (role === 'assistant') {
          if (sessionId) _activityLogStore.delete(sessionId);
          chatArea.querySelectorAll('.msg-typing-indicator').forEach(e => {
            e.classList.add('fade-out');
            setTimeout(() => e.remove(), 220);
          });
        }
      }
      if (wasNearBottom) chatScrollToBottom(false);
    }
  }
}

// --- Input Mode & Text Input ---
// --- Input mode (Auto / Typing) ---
let inputMode = 'voice'; // 'voice' or 'typing'
const modeToggle = document.getElementById('mode-toggle');
// Rearrange controls: row1=waveform, row2=cancel|mic|stop, row3=status (full width, no jump)
// cancel + pause both live in controls-left (absolutely positioned, mutually exclusive)
{
  const controlsEl = document.getElementById('controls');
  const controlsLeft = document.getElementById('controls-left');
  // Move cancel + pause buttons into left column (both absolute, only one shows at a time)
  controlsLeft.appendChild(document.getElementById('mic-cancel'));
  const pauseBtn = document.getElementById('transport-pause');
  if (pauseBtn) controlsLeft.appendChild(pauseBtn);
  // Create status row at bottom spanning all columns
  const statusRow = document.createElement('div');
  statusRow.id = 'controls-status';
  statusRow.appendChild(document.getElementById('status'));
  controlsEl.appendChild(statusRow);
  // Create top row for waveform
  const topRow = document.createElement('div');
  topRow.id = 'controls-top';
  topRow.appendChild(document.getElementById('waveform'));
  controlsEl.insertBefore(topRow, controlsEl.firstChild);
}
// textInputBar declared in DOM refs block above
const textInput = document.getElementById('text-input');
const textSendBtn = document.getElementById('text-send');

function cycleInputMode() {
  // Block switching to voice when text-only mode is enabled
  if (!sttEnabled) return;
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
  // updateLayout() is the single source of truth for controls/textInputBar visibility
  updateLayout();
  if (inputMode === 'typing') {
    requestAnimationFrame(() => { chatScrollToBottom(true); });
  }
}

// Activity log store for minimal mode typing indicator (per session)
const _activityLogStore = new Map(); // sessionId -> { texts: string[] }

// Typing indicator — show animated dots when agent is thinking/processing
function showTypingIndicator(sessionId) {
  // In verbose mode, activity log handles status — no dots needed
  if (typeof activityVerbose !== 'undefined' && activityVerbose) return;
  if (sessionId !== activeSessionId) return;
  const chatArea = document.getElementById('chat-area');
  if (!chatArea || chatArea.style.display === 'none') return;
  if (chatArea.querySelector('.msg-typing-indicator')) return; // already showing
  const el = document.createElement('div');
  el.className = 'msg assistant msg-typing-indicator';
  el.dataset.typingFor = sessionId;
  el.addEventListener('click', () => _toggleActivityExpand(el, sessionId));
  chatArea.appendChild(el);
  // Restore current tool activity text immediately (avoids blank dots until next tool call)
  const s = typeof sessions !== 'undefined' ? sessions.get(sessionId) : null;
  let savedText = s && s.toolStatusText ? s.toolStatusText : '';
  // Fall back to last log entry if toolStatusText is stale/empty (e.g. switching back to a busy tab)
  if (!savedText) {
    const log = _activityLogStore.get(sessionId);
    if (log && log.texts.length > 0) savedText = log.texts[log.texts.length - 1];
  }
  _renderTypingBubble(el, sessionId, savedText);
  chatScrollToBottom(false);
}

function hideTypingIndicator(sessionId) {
  const chatArea = document.getElementById('chat-area');
  if (!chatArea) return;
  chatArea.querySelectorAll('.msg-typing-indicator').forEach(el => {
    if (!sessionId || el.dataset.typingFor === sessionId) el.remove();
  });
  if (sessionId) _activityLogStore.delete(sessionId);
  else _activityLogStore.clear();
}

// Update typing indicator with latest activity text + count badge (minimal mode)
function _updateTypingIndicatorText(sessionId, text) {
  // Always accumulate into the log store, even for background sessions
  if (text) {
    if (!_activityLogStore.has(sessionId)) _activityLogStore.set(sessionId, { texts: [] });
    const log = _activityLogStore.get(sessionId);
    log.texts.push(text);
    if (log.texts.length > 30) log.texts.shift();
  }
  // Only update DOM for the active session
  if (sessionId !== activeSessionId) return;
  const chatArea = document.getElementById('chat-area');
  if (!chatArea || chatArea.style.display === 'none') return;

  let el = chatArea.querySelector('.msg-typing-indicator[data-typing-for="' + sessionId + '"]');
  if (!el) {
    el = document.createElement('div');
    el.className = 'msg assistant msg-typing-indicator';
    el.dataset.typingFor = sessionId;
    el.addEventListener('click', () => _toggleActivityExpand(el, sessionId));
    chatArea.appendChild(el);
  }
  _renderTypingBubble(el, sessionId, text);
  chatScrollToBottom(false);
}

function _renderTypingBubble(el, sessionId, currentText) {
  const log = _activityLogStore.get(sessionId);
  const count = log ? log.texts.length : 0;
  const esc = (t) => t.replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const dots = '<span class="typing-dot"></span><span class="typing-dot"></span><span class="typing-dot"></span>';
  const actText = currentText ? '<span class="typing-activity-text">' + esc(currentText) + '</span>' : '';
  const badge = count > 1 ? '<span class="typing-count-badge">+' + (count - 1) + '</span>' : '';

  // Incremental update — preserve .typing-log-expanded in DOM for CSS transitions
  let mainRow = el.querySelector('.typing-main-row');
  if (!mainRow) {
    mainRow = document.createElement('div');
    mainRow.className = 'typing-main-row';
    el.insertBefore(mainRow, el.firstChild);
  }
  mainRow.innerHTML = dots + actText + badge;

  if (log && log.texts.length > 0) {
    let logEl = el.querySelector('.typing-log-expanded');
    if (!logEl) {
      logEl = document.createElement('div');
      logEl.className = 'typing-log-expanded';
      el.appendChild(logEl);
    }
    logEl.innerHTML = log.texts.map((t, i) => {
      const cls = i === log.texts.length - 1 ? ' current' : '';
      return '<div class="typing-log-line' + cls + '">' + esc(t) + '</div>';
    }).join('');
  }
}

function _toggleActivityExpand(el, sessionId) {
  // Snapshot BEFORE class toggle — scrollHeight grows after expanding
  const wasNearBottom = chatArea.scrollTop + chatArea.clientHeight >= chatArea.scrollHeight - 200;
  el.classList.toggle('expanded');
  // Scroll log to bottom (latest entry) after transition completes
  if (el.classList.contains('expanded')) {
    setTimeout(() => {
      const logEl = el.querySelector('.typing-log-expanded');
      if (logEl) logEl.scrollTop = logEl.scrollHeight;
    }, 320); // after CSS transition (0.3s)
  }
  // Don't call _renderTypingBubble here — resets dot animations causing flash.
  // .typing-log-expanded is already in DOM; CSS transition handles the reveal.
  if (wasNearBottom) {
    if (_scrollRaf) { cancelAnimationFrame(_scrollRaf); _scrollRaf = null; }
    _easedScrollTo(chatArea);
  }
}

// Auto-resize textarea
textInput.addEventListener('input', () => {
  textInput.style.height = 'auto';
  textInput.style.height = Math.min(textInput.scrollHeight, 120) + 'px';
  textSendBtn.disabled = !textInput.value.trim();
});

// Send on Enter (Shift+Enter for newline) — desktop only
// On mobile, Enter inserts newline; the send button handles sending
textInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !isMobile) {
    e.preventDefault();
    sendTextMessage();
  }
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

