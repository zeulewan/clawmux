// ClawMux — Chat Tools Module
// Tool card rendering, thinking decode animation, permission cards, diff view.
// Dependencies: state.js (sessions, activeSessionId), hub.html (chatArea, chatScrollToBottom)

// === Claude JSON: Tool Card Rendering ===
const _THINKING_GLYPHS = ['·', '✢', '*', '✶', '✻', '✽'];
const _THINKING_VERBS = ['Thinking', 'Reasoning', 'Considering', 'Pondering', 'Analyzing', 'Working'];
let _thinkingInterval = null;
let _thinkingDecodeInterval = null;

function _toolInputSummary(toolName, data) {
  if (!data || typeof data !== 'object') return '';
  if (toolName === 'Bash' && data.command) return data.command.length > 80 ? data.command.slice(0, 77) + '...' : data.command;
  if ((toolName === 'Read' || toolName === 'Write' || toolName === 'Edit') && data.file_path) return data.file_path;
  if (toolName === 'Grep' && data.pattern) return data.pattern;
  if (toolName === 'Glob' && data.pattern) return data.pattern;
  if (toolName === 'Agent' && data.prompt) return data.prompt.slice(0, 60) + '...';
  // Fallback: show first string value from data
  for (const v of Object.values(data)) {
    if (typeof v === 'string' && v.length > 0) return v.length > 80 ? v.slice(0, 77) + '...' : v;
  }
  return '';
}

function _toolInputFormatted(toolName, data) {
  if (!data) return '';
  if (toolName === 'Bash') return data.command || '';
  if (toolName === 'Read') return data.file_path || '';
  if (toolName === 'Write') return `${data.file_path || ''}\n${(data.content || '').slice(0, 500)}`;
  if (toolName === 'Edit') return `${data.file_path || ''}\n- ${(data.old_string || '').slice(0, 200)}\n+ ${(data.new_string || '').slice(0, 200)}`;
  if (toolName === 'Grep') return `pattern: ${data.pattern || ''}\npath: ${data.path || '.'}`;
  if (toolName === 'Glob') return `pattern: ${data.pattern || ''}`;
  return JSON.stringify(data, null, 2).slice(0, 500);
}

// Read-only tools that qualify for "Explored N" collapsing
const _READONLY_TOOLS = new Set(['Read', 'Grep', 'Glob', 'Search', 'WebFetch', 'WebSearch']);

function createToolCardEl(msg) {
  const details = document.createElement('details');
  const statusClass = msg.toolStatus === 'done' ? 'status-success' : (msg.toolStatus === 'error' ? 'status-error' : 'status-running');
  details.className = 'tool-card ' + statusClass;
  if (msg.id) details.dataset.msgId = msg.id;
  details.dataset.toolId = msg.toolId || '';
  details.dataset.toolName = msg.toolName || '';

  // Summary: tool name (bold) + secondary info (monospace, link color)
  const summary = document.createElement('summary');
  summary.className = 'tool-card-header';
  const summaryInner = document.createElement('div');
  summaryInner.className = 'tool-card-summary-inner';
  const nameEl = document.createElement('span');
  nameEl.className = 'tool-card-name';
  nameEl.textContent = msg.toolName || 'Tool';
  summaryInner.appendChild(nameEl);
  const secondary = _toolInputSummary(msg.toolName, msg.toolData);
  if (secondary) {
    const secEl = document.createElement('span');
    secEl.className = 'tool-card-secondary';
    secEl.textContent = secondary;
    summaryInner.appendChild(secEl);
  }
  summary.appendChild(summaryInner);
  details.appendChild(summary);

  // Body: grid with IN row (and OUT row if result available)
  const grid = document.createElement('div');
  grid.className = 'tool-body-grid';

  // IN row
  const inRow = document.createElement('div');
  inRow.className = 'tool-body-row';
  const inLabel = document.createElement('span');
  inLabel.className = 'tool-body-label';
  inLabel.textContent = 'IN';
  inRow.appendChild(inLabel);
  const inContent = document.createElement('div');
  inContent.className = 'tool-body-content';
  const formatted = _toolInputFormatted(msg.toolName, msg.toolData);
  const pre = document.createElement('pre');
  pre.textContent = formatted;
  inContent.appendChild(pre);
  inRow.appendChild(inContent);
  grid.appendChild(inRow);

  // OUT row (if tool result is available)
  if (msg.toolOutput) {
    const outRow = document.createElement('div');
    outRow.className = 'tool-body-row';
    const outLabel = document.createElement('span');
    outLabel.className = 'tool-body-label';
    outLabel.textContent = 'OUT';
    outRow.appendChild(outLabel);
    const outContent = document.createElement('div');
    outContent.className = 'tool-body-content';
    const outPre = document.createElement('pre');
    outPre.textContent = typeof msg.toolOutput === 'string' ? msg.toolOutput.slice(0, 2000) : JSON.stringify(msg.toolOutput, null, 2).slice(0, 2000);
    outContent.appendChild(outPre);
    outRow.appendChild(outContent);
    grid.appendChild(outRow);
  }

  // Annotation badge
  if (msg.toolStatus === 'done' || msg.toolStatus === 'error') {
    const badge = document.createElement('span');
    badge.className = 'tool-annotation ' + (msg.toolStatus === 'error' ? 'error' : 'success');
    badge.textContent = msg.toolStatus === 'error' ? 'Error' : 'Success';
    grid.appendChild(badge);
  }

  details.appendChild(grid);
  return details;
}

// Update tool card when result arrives — status class + re-render with output
function updateToolCardStatus(sessionId, status) {
  const chatArea = document.getElementById('chat-area');
  if (!chatArea || sessionId !== activeSessionId) return;
  const s = sessions.get(sessionId);
  if (!s) return;
  // Find the message that was just updated and its corresponding card
  const cards = chatArea.querySelectorAll('.tool-card.status-running');
  for (let i = cards.length - 1; i >= 0; i--) {
    const card = cards[i];
    // Update status class
    card.classList.remove('status-running');
    card.classList.add(status === 'error' ? 'status-error' : 'status-success');
    // Update dot if present
    const dot = card.querySelector('.tool-status-dot.running');
    if (dot) dot.className = 'tool-status-dot ' + (status === 'error' ? 'error' : 'success');
    // Re-render card with output by replacing it
    const toolId = card.dataset.toolId;
    if (toolId) {
      const msg = s.messages.find(m => m.toolId === toolId);
      if (msg && msg.toolOutput) {
        const newCard = createToolCardEl(msg);
        card.replaceWith(newCard);
      }
    }
    break;
  }
}

// Group consecutive tool cards behind a toggle
function _groupToolCards(chatArea) {
  const children = [...chatArea.children];
  let groupStart = -1;
  let count = 0;

  for (let i = 0; i <= children.length; i++) {
    const el = i < children.length ? children[i] : null;
    const isReadOnlyTool = el && el.classList.contains('tool-card') && _READONLY_TOOLS.has(el.dataset.toolName || '');
    if (isReadOnlyTool) {
      if (groupStart < 0) groupStart = i;
      count++;
    } else {
      if (count >= 3) {
        // Collect references to the actual DOM nodes (not indices)
        const hiddenCards = [];
        for (let j = groupStart + 1; j < groupStart + count - 1; j++) {
          hiddenCards.push(children[j]);
          children[j].classList.add('tool-group-hidden');
        }
        const toggle = document.createElement('details');
        toggle.className = 'tool-group-toggle';
        const toggleSummary = document.createElement('summary');
        toggleSummary.textContent = 'Explored ' + count + ' tools';
        toggle.appendChild(toggleSummary);
        chatArea.insertBefore(toggle, children[groupStart]);
        toggle.addEventListener('toggle', () => {
          hiddenCards.forEach(card => card.classList.toggle('tool-group-hidden', !toggle.open));
        });
      }
      groupStart = -1;
      count = 0;
    }
  }
}

// Thinking decode animation for claude-json
function showThinkingDecode(sessionId) {
  if (sessionId !== activeSessionId) return;
  const chatArea = document.getElementById('chat-area');
  if (!chatArea) return;
  // Don't duplicate
  if (chatArea.querySelector('.thinking-decode')) return;

  const el = document.createElement('div');
  el.className = 'msg assistant thinking-decode';
  el.dataset.typingFor = sessionId;

  const glyphEl = document.createElement('span');
  glyphEl.className = 'thinking-glyph';
  glyphEl.textContent = _THINKING_GLYPHS[0];
  el.appendChild(glyphEl);

  const textEl = document.createElement('span');
  textEl.className = 'thinking-text';
  el.appendChild(textEl);

  chatArea.appendChild(el);
  chatScrollToBottom(false);

  // Glyph cycle
  let gi = 0;
  _thinkingInterval = setInterval(() => {
    gi = (gi + 1) % _THINKING_GLYPHS.length;
    glyphEl.textContent = _THINKING_GLYPHS[gi];
  }, 120);

  // Typewriter decode
  const verb = _THINKING_VERBS[Math.floor(Math.random() * _THINKING_VERBS.length)] + '...';
  let ci = 0;
  _thinkingDecodeInterval = setInterval(() => {
    if (ci < verb.length) {
      textEl.textContent = verb.slice(0, ci + 1);
      ci++;
    } else {
      textEl.innerHTML = verb + '<span class="thinking-cursor">\u258C</span>';
      clearInterval(_thinkingDecodeInterval);
      _thinkingDecodeInterval = null;
    }
  }, 40);
}

function hideThinkingDecode(sessionId) {
  if (_thinkingInterval) { clearInterval(_thinkingInterval); _thinkingInterval = null; }
  if (_thinkingDecodeInterval) { clearInterval(_thinkingDecodeInterval); _thinkingDecodeInterval = null; }
  const chatArea = document.getElementById('chat-area');
  if (!chatArea) return;
  chatArea.querySelectorAll('.thinking-decode').forEach(el => {
    if (!sessionId || el.dataset.typingFor === sessionId) el.remove();
  });
}

// === Permission Request Card ===
function renderPermissionCard(sessionId, reqData) {
  if (sessionId !== activeSessionId) return;
  const chatArea = document.getElementById('chat-area');
  if (!chatArea) return;

  const card = document.createElement('div');
  card.className = 'permission-card';
  card.dataset.requestId = reqData.request_id || '';

  const header = document.createElement('div');
  header.className = 'permission-header';
  header.textContent = reqData.title || `Allow ${reqData.display_name || reqData.tool_name || 'tool'}?`;
  card.appendChild(header);

  if (reqData.description) {
    const desc = document.createElement('div');
    desc.className = 'permission-desc';
    desc.textContent = reqData.description;
    card.appendChild(desc);
  }

  // Input preview
  if (reqData.input) {
    const preview = document.createElement('pre');
    preview.className = 'permission-preview';
    const inputStr = typeof reqData.input === 'string' ? reqData.input : JSON.stringify(reqData.input, null, 2);
    preview.textContent = inputStr.slice(0, 500);
    card.appendChild(preview);
  }

  // Action buttons
  const actions = document.createElement('div');
  actions.className = 'permission-actions';

  const allowBtn = document.createElement('button');
  allowBtn.className = 'permission-btn allow';
  allowBtn.textContent = 'Allow';
  allowBtn.onclick = () => _respondPermission(sessionId, reqData.request_id, true, card);
  actions.appendChild(allowBtn);

  const denyBtn = document.createElement('button');
  denyBtn.className = 'permission-btn deny';
  denyBtn.textContent = 'Deny';
  denyBtn.onclick = () => _respondPermission(sessionId, reqData.request_id, false, card);
  actions.appendChild(denyBtn);

  card.appendChild(actions);
  chatArea.appendChild(card);
  chatScrollToBottom(true);
}

async function _respondPermission(sessionId, requestId, allow, cardEl) {
  try {
    await fetch(`/api/sessions/${sessionId}/permission-response`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ request_id: requestId, allow, message: '' }),
    });
    // Replace card with result indicator
    cardEl.className = 'permission-card ' + (allow ? 'resolved-allow' : 'resolved-deny');
    cardEl.innerHTML = `<div class="permission-result">${allow ? '\u2705 Allowed' : '\u274C Denied'}: ${cardEl.dataset.requestId}</div>`;
  } catch (e) {
    console.error('Permission response failed:', e);
  }
}

// === Permission Mode Picker ===
const _PERMISSION_MODES = ['bypassPermissions', 'auto', 'acceptEdits', 'plan', 'dontAsk'];
const _PERMISSION_LABELS = { bypassPermissions: 'Bypass', auto: 'Auto', acceptEdits: 'Accept Edits', plan: 'Plan', dontAsk: "Don't Ask" };

async function cyclePermissionMode() {
  if (!activeSessionId) return;
  const s = sessions.get(activeSessionId);
  if (!s || s.backend !== 'claude-json') return;
  const current = s.permissionMode || 'bypassPermissions';
  const idx = _PERMISSION_MODES.indexOf(current);
  const next = _PERMISSION_MODES[(idx + 1) % _PERMISSION_MODES.length];
  try {
    await fetch(`/api/sessions/${activeSessionId}/permission-mode`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: next }),
    });
    s.permissionMode = next;
    updatePermissionModeLabel();
  } catch (e) { console.error('Failed to set permission mode:', e); }
}

// === DiffView Renderer ===
function renderDiffView(sessionId, reqData) {
  if (sessionId !== activeSessionId) return;
  const chatArea = document.getElementById('chat-area');
  if (!chatArea) return;
  const diff = reqData.diff || {};
  const filePath = diff.file_path || 'unknown';
  const fileName = filePath.split('/').pop();

  const card = document.createElement('div');
  card.className = 'diff-card';
  card.dataset.requestId = reqData.request_id || '';

  // Header
  const header = document.createElement('div');
  header.className = 'diff-header';
  const toolLabel = reqData.tool_name === 'Edit' ? 'Edit' : (diff.is_new_file ? 'New File' : 'Write');
  header.innerHTML = `<span class="diff-tool-badge">${toolLabel}</span> <span class="diff-filename">${_escHtml(fileName)}</span>`;
  card.appendChild(header);

  const pathEl = document.createElement('div');
  pathEl.className = 'diff-filepath';
  pathEl.textContent = filePath;
  card.appendChild(pathEl);

  // Diff content
  const diffBody = document.createElement('div');
  diffBody.className = 'diff-body';
  if (reqData.tool_name === 'Edit' && diff.old_string !== undefined) {
    _renderUnifiedDiff(diffBody, diff.old_string || '', diff.new_string || '');
  } else {
    _renderUnifiedDiff(diffBody, diff.old_content || '', diff.new_content || '');
  }
  card.appendChild(diffBody);

  // Actions
  const actions = document.createElement('div');
  actions.className = 'diff-actions';
  const acceptBtn = document.createElement('button');
  acceptBtn.className = 'permission-btn allow';
  acceptBtn.textContent = 'Accept';
  acceptBtn.onclick = () => _respondDiff(sessionId, reqData.request_id, true, card);
  actions.appendChild(acceptBtn);
  const rejectBtn = document.createElement('button');
  rejectBtn.className = 'permission-btn deny';
  rejectBtn.textContent = 'Reject';
  rejectBtn.onclick = () => _respondDiff(sessionId, reqData.request_id, false, card);
  actions.appendChild(rejectBtn);
  card.appendChild(actions);

  chatArea.appendChild(card);
  chatScrollToBottom(true);
}

function _renderUnifiedDiff(container, oldText, newText) {
  const oldLines = oldText.split('\n');
  const newLines = newText.split('\n');
  let html = '';
  let oi = 0, ni = 0;
  while (oi < oldLines.length || ni < newLines.length) {
    const ol = oi < oldLines.length ? oldLines[oi] : null;
    const nl = ni < newLines.length ? newLines[ni] : null;
    if (ol === nl) {
      html += `<div class="diff-line ctx"><span class="diff-ln">${oi + 1}</span><span class="diff-code"> ${_escHtml(ol)}</span></div>`;
      oi++; ni++;
    } else {
      if (ol !== null) {
        html += `<div class="diff-line del"><span class="diff-ln">${oi + 1}</span><span class="diff-code">-${_escHtml(ol)}</span></div>`;
        oi++;
      }
      if (nl !== null && (ol === null || ol !== nl)) {
        html += `<div class="diff-line add"><span class="diff-ln">${ni + 1}</span><span class="diff-code">+${_escHtml(nl)}</span></div>`;
        ni++;
      }
    }
    if (oi + ni > 2000) break;
  }
  container.innerHTML = html;
}

function _escHtml(s) {
  return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function _respondDiff(sessionId, requestId, allow, cardEl) {
  try {
    await fetch(`/api/sessions/${sessionId}/permission-response`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ request_id: requestId, allow, message: '' }),
    });
    cardEl.className = 'diff-card ' + (allow ? 'resolved-accept' : 'resolved-reject');
    const result = document.createElement('div');
    result.className = 'diff-result';
    result.textContent = allow ? '\u2705 Accepted' : '\u274C Rejected';
    cardEl.querySelector('.diff-actions')?.remove();
    cardEl.appendChild(result);
  } catch (e) { console.error('Diff response failed:', e); }
}

function updatePermissionModeLabel() {
  const el = document.getElementById('permission-mode-label');
  if (!el) return;
  const s = activeSessionId ? sessions.get(activeSessionId) : null;
  if (!s || s.backend !== 'claude-json') { el.style.display = 'none'; return; }
  const mode = s.permissionMode || 'bypassPermissions';
  el.textContent = (_PERMISSION_LABELS[mode] || mode) + ' \u25BE';
  el.style.display = 'inline';
}
