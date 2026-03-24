// ClawMux — Per-Backend Renderer Abstraction
//
// Each backend gets a renderer that controls how messages, tool cards,
// indicators, permissions, diffs, and history are rendered in the chat.
//
// Dependencies (global): sessions, activeSessionId, chatArea,
//   createMsgEl, createToolCardEl, voiceColor, voiceDisplayName,
//   showTypingIndicator, hideTypingIndicator, _updateTypingIndicatorText,
//   showThinkingDecode, hideThinkingDecode, startThinkingSound,
//   renderPermissionCard, renderDiffView, chatScrollToBottom

const _renderers = {};

function registerRenderer(backend, renderer) {
  _renderers[backend] = renderer;
}

function getRenderer(backendOrSessionId) {
  // Accept either a backend string or a session ID
  let backend = backendOrSessionId;
  if (typeof sessions !== 'undefined' && sessions.has(backendOrSessionId)) {
    const s = sessions.get(backendOrSessionId);
    backend = s ? s.backend : 'claude-code';
  }
  return _renderers[backend] || _renderers['default'];
}

// Convenience: get renderer for the active session
function activeRenderer() {
  if (!activeSessionId) return _renderers['default'];
  return getRenderer(activeSessionId);
}

// === Default Renderer (claude-code / tmux backends) ===
registerRenderer('default', {
  name: 'default',

  // History: use ClawMux history API (voice-based)
  historyUrl(session) {
    const project = typeof currentProject !== 'undefined' ? currentProject : '';
    return `/api/history/${session.voice}?limit=150${project ? '&project=' + encodeURIComponent(project) : ''}`;
  },

  // Transcript messages: skip tool_calls (tools shown in tmux terminal)
  processTranscriptMessage(msg, messages) {
    if (msg.text) {
      const obj = { role: msg.role, text: msg.text };
      if (msg.uuid) obj.id = msg.uuid;
      else if (msg.id) obj.id = msg.id;
      if (msg.ts) obj.ts = msg.ts;
      if (msg.parent_id) obj.parentId = msg.parent_id;
      if (msg.bare_ack) obj.isBareAck = true;
      messages.push(obj);
    }
  },

  // Tool cards: not rendered for tmux backends
  renderToolCard(msg) { return null; },

  // Indicators: typing dots + activity text
  showIndicator(sessionId, type, data) {
    if (typeof showTypingIndicator === 'function') showTypingIndicator(sessionId);
    if (data && data.text && typeof _updateTypingIndicatorText === 'function') {
      _updateTypingIndicatorText(sessionId, data.text);
    }
  },
  hideIndicator(sessionId) {
    if (typeof hideTypingIndicator === 'function') hideTypingIndicator(sessionId);
  },
  startSound(sessionId) {
    if (typeof startThinkingSound === 'function') startThinkingSound(sessionId);
  },

  // Idle status: show "Ready" text
  showIdleStatus(sessionId) {
    if (typeof showIdleStatus === 'function') showIdleStatus(sessionId);
  },
  setIdleStatusText(sessionId) {
    if (typeof setStatus === 'function') setStatus('Ready', sessionId);
  },

  // Activity text: update from session_status events
  updateActivity(session, data) {
    if ('activity' in data) session.toolStatusText = data.activity || '';
    if ('tool_name' in data) session.toolName = data.tool_name || '';
  },

  // Activity text messages: render via typing indicator
  handleActivityText(sessionId, text) {
    if (typeof addMessage === 'function') addMessage(sessionId, 'activity', text);
  },

  // Permission/diff: not supported for tmux backends
  renderPermission(sessionId, data) { return false; },
  renderDiff(sessionId, data) { return false; },

  // Voice color
  bubbleColor(session) {
    return typeof voiceColor === 'function' ? voiceColor(session.voice) : '#4a90ff';
  },

  // Status text on switchTab
  switchTabStatus(session) {
    return session.statusText || 'Ready';
  },
});

// === Claude Code Renderer (inherits default) ===
registerRenderer('claude-code', {
  ..._renderers['default'],
  name: 'claude-code',

  // Claude Code (tmux): use ClawMux history API — transcript requires
  // conversation_id which is lost on hub reload for adopted sessions
  historyUrl(session) {
    const project = typeof currentProject !== 'undefined' ? currentProject : '';
    return `/api/history/${session.voice}?limit=150${project ? '&project=' + encodeURIComponent(project) : ''}`;
  },
});

// === Claude JSON Renderer (VS Code extension style) ===
registerRenderer('claude-json', {
  name: 'claude-json',

  // History: use ClawMux history API — the agent's spoken responses go through
  // clawmux send (saved to history.json), not through the JSONL transcript
  // which only has tool calls. Same source as claude-code.
  historyUrl(session) {
    const project = typeof currentProject !== 'undefined' ? currentProject : '';
    return `/api/history/${session.voice}?limit=150${project ? '&project=' + encodeURIComponent(project) : ''}`;
  },

  // Transcript: process full Anthropic content blocks
  processTranscriptMessage(msg, messages) {
    const content = msg.content;
    const ts = msg.ts || 0;
    // If content blocks are available, process each block by type
    if (Array.isArray(content) && content.length > 0) {
      for (const block of content) {
        if (!block || typeof block !== 'object') continue;
        if (block.type === 'text' && block.text) {
          messages.push({
            role: msg.role, text: block.text,
            id: msg.uuid || msg.id || undefined, ts,
          });
        } else if (block.type === 'tool_use') {
          messages.push({
            role: 'tool', toolName: block.name, toolData: block.input || {},
            toolStatus: 'done', toolId: block.id || ('hist-' + Date.now()),
            ts,
          });
        } else if (block.type === 'tool_result') {
          // Fill in the OUT row of the matching tool card
          const toolUseId = block.tool_use_id;
          if (toolUseId) {
            for (let i = messages.length - 1; i >= 0; i--) {
              if (messages[i].role === 'tool' && messages[i].toolId === toolUseId) {
                const resultContent = block.content;
                messages[i].toolOutput = typeof resultContent === 'string'
                  ? resultContent
                  : Array.isArray(resultContent)
                    ? resultContent.filter(b => b.type === 'text').map(b => b.text).join('\n')
                    : JSON.stringify(resultContent);
                if (block.is_error) messages[i].toolStatus = 'error';
                break;
              }
            }
          }
        } else if (block.type === 'thinking' && block.text) {
          messages.push({
            role: 'thinking', text: block.text, ts,
            thinkingDuration: block.duration || null,
          });
        }
      }
      return;
    }
    // Fallback: legacy format with tool_calls array
    if (msg.tool_calls && msg.tool_calls.length > 0) {
      for (const tc of msg.tool_calls) {
        messages.push({
          role: 'tool', toolName: tc.name, toolData: tc.input || {},
          toolStatus: 'done', toolId: 'hist-' + (tc.id || Date.now()), ts,
        });
      }
    }
    if (msg.text) {
      messages.push({
        role: msg.role, text: msg.text,
        id: msg.uuid || msg.id || undefined, ts,
        parentId: msg.parent_id || undefined,
        isBareAck: msg.bare_ack || undefined,
      });
    }
  },

  // Tool cards: rendered inline in chat
  renderToolCard(msg) {
    return typeof createToolCardEl === 'function' ? createToolCardEl(msg) : null;
  },

  // Indicators: thinking decode animation
  showIndicator(sessionId, type, data) {
    if (typeof showThinkingDecode === 'function') showThinkingDecode(sessionId);
  },
  hideIndicator(sessionId) {
    if (typeof hideThinkingDecode === 'function') hideThinkingDecode(sessionId);
  },
  startSound(sessionId) { /* no thinking sound for json backend */ },

  // Idle status: silent (no "Ready" text)
  showIdleStatus(sessionId) { },
  setIdleStatusText(sessionId) {
    if (typeof setStatus === 'function') setStatus('', sessionId);
  },

  // Activity text: skip (uses structured_event instead)
  updateActivity(session, data) { /* managed by structured_event */ },
  handleActivityText(sessionId, text) { /* skip */ },

  // Permission/diff: supported
  renderPermission(sessionId, data) {
    if (typeof renderPermissionCard === 'function') { renderPermissionCard(sessionId, data); return true; }
    return false;
  },
  renderDiff(sessionId, data) {
    if (typeof renderDiffView === 'function') { renderDiffView(sessionId, data); return true; }
    return false;
  },

  // Bubble color: none (full-width, no background)
  bubbleColor(session) { return 'transparent'; },

  // Status text on switchTab: empty
  switchTabStatus(session) { return ''; },
});

// === OpenClaw Renderer ===
registerRenderer('openclaw', {
  ..._renderers['default'],
  name: 'openclaw',

  // History: OpenClaw-specific endpoint
  historyUrl(session) {
    return `/api/openclaw/history/${session.session_id}?limit=150`;
  },

  // Tool cards: not rendered
  renderToolCard(msg) { return null; },

  // Green bubble color
  bubbleColor(session) { return '#2ecc71'; },
});

// === Codex Renderer (same as default/claude-code for now) ===
registerRenderer('codex', {
  ..._renderers['default'],
  name: 'codex',
});
