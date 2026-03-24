// ClawMux — Chat Module (Orchestrator)
// addMessage, renderChat, scroll management, history loading, typing indicators.
// Dependencies: chat-render.js, chat-tools.js, chat-input.js,
//   state.js, sidebar.js, audio.js, renderers.js

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
  const vc = getRenderer(activeSessionId).bubbleColor(s);
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
    // Tool call cards (claude-json)
    if (msg.role === 'tool') {
      chatArea.appendChild(createToolCardEl(msg));
      continue;
    }
    // Thinking blocks (verbose mode only)
    if (msg.role === 'thinking') {
      if (typeof isVerboseMode === 'function' && isVerboseMode()) {
        const details = document.createElement('details');
        details.className = 'verbose-thinking';
        const summary = document.createElement('summary');
        const dur = msg.thinkingDuration ? ' (' + msg.thinkingDuration + 's)' : '';
        const tokens = Math.ceil((msg.text || '').length / 4);
        summary.textContent = '\u25B8 Thought' + dur + (tokens ? ' ~' + tokens + ' tokens' : '');
        details.appendChild(summary);
        const body = document.createElement('div');
        body.className = 'thinking-body';
        body.textContent = msg.text || '';
        details.appendChild(body);
        chatArea.appendChild(details);
      }
      continue;
    }
    // Usage stats (verbose mode only)
    if (msg.role === 'usage') {
      if (typeof isVerboseMode === 'function' && isVerboseMode()) {
        const u = msg.usage || {};
        const input = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
        const output = u.output_tokens || 0;
        const cache = u.cache_read_input_tokens || 0;
        const parts = [input.toLocaleString() + ' in', output.toLocaleString() + ' out'];
        if (cache) parts.push(cache.toLocaleString() + ' cache');
        const el = document.createElement('div');
        el.className = 'verbose-usage';
        el.textContent = parts.join(' \u00B7 ');
        chatArea.appendChild(el);
      }
      continue;
    }
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
  // Group consecutive tool cards (claude-json)
  if (s && s.backend === 'claude-json') _groupToolCards(chatArea);
  // Restore indicator if session is currently active
  if (s && s.sessionState === 'processing') {
    getRenderer(activeSessionId).showIndicator(activeSessionId);
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

  // Find cursor for pagination: prefer oldest message ID, fall back to oldest timestamp
  let oldestId = null;
  let oldestTs = null;
  for (let i = 0; i < s.messages.length; i++) {
    if (s.messages[i].id && !oldestId) { oldestId = s.messages[i].id; }
    if (s.messages[i].ts && (!oldestTs || s.messages[i].ts < oldestTs)) { oldestTs = s.messages[i].ts; }
  }

  try {
    const project = typeof currentProject !== 'undefined' ? currentProject : '';
    let cursor = '';
    if (oldestId) cursor = '&before=' + encodeURIComponent(oldestId);
    else if (oldestTs) cursor = '&before_ts=' + oldestTs;
    let url;
    if (s.backend === 'openclaw') {
      url = `/api/openclaw/history/${sessionId}?limit=150${cursor}`;
    } else if (typeof _isClaudeBackend === 'function' && _isClaudeBackend(s.backend)) {
      url = `/api/sessions/${sessionId}/transcript?limit=50${cursor}`;
    } else {
      url = `/api/history/${s.voice}?limit=150${cursor}${project ? '&project=' + encodeURIComponent(project) : ''}`;
    }
    console.log('[_fetchOlderHistory] fetching:', url, { oldestId, oldestTs });
    const resp = await fetch(url);
    if (!resp.ok) throw new Error('fetch failed: ' + resp.status);
    const hist = await resp.json();
    console.log('[_fetchOlderHistory] got', (hist.messages || []).length, 'msgs, has_more:', hist.has_more);
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
      console.log('[_fetchOlderHistory] after dedup:', newMsgs.length, 'new msgs (of', olderMsgs.length, 'fetched)');
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
    // Re-check: if viewport still isn't filled, keep fetching (activity-heavy agents)
    if (sessionId === activeSessionId) {
      requestAnimationFrame(() => {
        if (typeof _fillViewportMessages === 'function') _fillViewportMessages();
      });
    }
  }
}

// Fill the viewport on tab switch. With visible-limit semantics, _CHAT_BATCH (50) visible
// messages should always fill any mobile screen. This is a light fallback for sessions
// with very few real messages total (e.g. 1-3 messages — they're all shown, nothing to fill).
function _fillViewportMessages() {
  if (!activeSessionId) return;
  const s = sessions.get(activeSessionId);
  if (!s) return;
  const filled = chatArea.scrollHeight > chatArea.clientHeight + 10;
  const limit = _getChatLimit(activeSessionId);
  const { hasMore: localHasMore } = _getDisplaySlice(s.messages, limit);
  const visibleCount = s.messages.filter(m => !m.parentId && m.role !== 'activity').length;
  console.log('[_fillViewportMessages]', { filled, scrollH: chatArea.scrollHeight, clientH: chatArea.clientHeight, localHasMore, hasMoreHistory: s.hasMoreHistory, loading: s.loadingOlderHistory, totalMsgs: s.messages.length, visibleCount, limit });
  if (filled) return; // already filled
  if (localHasMore) {
    _chatRenderLimit.set(activeSessionId, limit + _CHAT_BATCH);
    _scrollLoadPending = true;
    renderChat(true);
    requestAnimationFrame(() => { _scrollLoadPending = false; });
    return;
  }
  // Local buffer exhausted but server has more — fetch older page
  if (s.hasMoreHistory && !s.loadingOlderHistory) {
    console.log('[_fillViewportMessages] triggering _fetchOlderHistory');
    _fetchOlderHistory(activeSessionId);
  }
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

// Tool card expand/collapse uses native <details>/<summary> — no JS handler needed

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
      const vc = getRenderer(activeSessionId).bubbleColor(s);
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

// Legacy compat wrappers — redirect to renderer registry (renderers.js)
function showAgentIndicator(sid, t, d) { getRenderer(sid).showIndicator(sid, t, d); }
function hideAgentIndicator(sid) { getRenderer(sid).hideIndicator(sid); }
function startAgentThinkingSound(sid) { getRenderer(sid).startSound(sid); }
