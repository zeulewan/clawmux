// ClawMux — WebSocket Connection & Message Handling
// Extracted from hub.html Phase 1 refactor.
// All functions and variables remain global (window-scoped).
//
// Dependencies (defined in state.js and hub.html inline script):
//   state.js: sessions, activeSessionId, ws, autoMode, vadEnabled,
//             autoInterruptEnabled, ttsEnabled, sttEnabled, currentAudio,
//             currentBufferedPlayer, playbackPaused, showAgentMessages,
//             recording, micMuted
//   hub.html: setConnected, setStatus, showCopyToast, _flushPendingAudio,
//             setToggle, renderSidebar, renderVoiceGridIfActive, addSession,
//             removeSession, switchTab, addMessage, setSessionSidebarState,
//             setSessionState, hideThinking, stopThinkingSound,
//             updateThinkingLabel, cueSessionReady, loadProjects,
//             markSessionUnread, clearSessionUnread, enqueueAudio,
//             updateMicUI, startPlaybackVAD, _handleListeningUI,
//             terminateSession, karaokeSetupMessage, chatArea,
//             updateHeaderProjectStatus, renderChat, chatScrollToBottom,
//             _karaokeWords, _applyKaraokeSpans, currentProject,
//             currentProjectVoices, getSessionState, updateTransportBar

// --- WebSocket ---
let _wsHasConnected = false;
function connect() {
  setConnected('connecting');
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const url = `${proto}//${location.host}/ws`;
  ws = new WebSocket(url);

  ws.onopen = () => {
    setConnected('connected');
    if (!_wsHasConnected && window._loadingBar) window._loadingBar.advance(50);
    if (_wsHasConnected) showCopyToast('Hub reconnected');
    _wsHasConnected = true;
    if (!activeSessionId) setStatus('Connected');
    // Flush any audio that was recorded during disconnect
    _flushPendingAudio();
    // Restore persisted settings
    fetch('/api/settings').then(r => r.json()).then(s => {
      autoMode = s.auto_record || false;
      vadEnabled = s.auto_end !== false;
      autoInterruptEnabled = s.auto_interrupt || false;
      setToggle('auto_record', autoMode);
      setToggle('auto_end', vadEnabled);
      setToggle('auto_interrupt', autoInterruptEnabled);
      ttsEnabled = s.tts_enabled !== false;
      setToggle('tts_enabled', ttsEnabled);
      sttEnabled = s.stt_enabled !== false;
      setToggle('stt_enabled', sttEnabled);
    }).catch(e => console.warn('settings reload:', e));
  };

  ws.onclose = () => {
    setConnected('disconnected');
    ws = null;
    setTimeout(connect, 2000);
  };

  ws.onerror = () => { ws?.close(); };

  ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (_sessionsLoading) {
      _messageBuffer.push(data);
    } else {
      handleMessage(data);
    }
  };
}

let _sessionsLoading = false;
const _messageBuffer = [];

// Cursor-based reconnect sync — fetches only messages after the last known ID
async function _reconnectSyncSession(sessionId, voiceId) {
  const s = sessions.get(sessionId);
  if (!s || !s.messages.length) return;
  // Find last message with an ID (cursor)
  let lastId = null;
  for (let i = s.messages.length - 1; i >= 0; i--) {
    if (s.messages[i].id) { lastId = s.messages[i].id; break; }
  }
  if (!lastId) return;
  try {
    const resp = await fetch(`/api/history/${voiceId}?project=${currentProject}&after=${encodeURIComponent(lastId)}`);
    if (!resp.ok) return;
    const hist = await resp.json();
    const newMessages = (hist.messages || []).map(m => {
      const obj = { role: m.role, text: m.text };
      if (m.id) obj.id = m.id;
      if (m.ts) obj.ts = m.ts;
      if (m.parent_id) obj.parentId = m.parent_id;
      if (m.bare_ack) obj.isBareAck = true;
      return obj;
    });
    if (newMessages.length > 0) {
      console.log(`[reconnectSync] ${sessionId}: appending ${newMessages.length} missed messages`);
      for (const msg of newMessages) {
        addMessage(sessionId, msg.role, msg.text, {
          id: msg.id || null,
          parentId: msg.parentId || null,
          isBareAck: msg.isBareAck || false,
        });
      }
    }
  } catch (e) { /* ignore */ }
}

function _reconnectSync() {
  for (const [sid, s] of sessions) {
    if (s.voice) _reconnectSyncSession(sid, s.voice);
  }
}

function _flushMessageBuffer() {
  while (_messageBuffer.length > 0) {
    handleMessage(_messageBuffer.shift());
  }
}

function handleMessage(data) {
  const { type, session_id } = data;

  // Heartbeat — ignore pings
  if (type === 'ping') return;

  // Hub-level messages (no session_id)
  if (type === 'session_list') {
    _sessionsLoading = true;
    if (window._loadingBar) window._loadingBar.advance(75);
    const promises = [];
    for (const s of data.sessions) {
      if (!sessions.has(s.session_id)) {
        promises.push(addSession(s, false));
      } else {
        // Session already exists — cursor-based sync and restore state
        promises.push(_reconnectSyncSession(s.session_id, s.voice));
        const existing = sessions.get(s.session_id);
        if (existing) {
          existing.speed = s.speed || existing.speed;
          existing.model = s.model || existing.model;
          existing.effort = s.effort || existing.effort;
          existing.backend = s.backend !== undefined ? s.backend : existing.backend;
          existing.model_id = s.model_id !== undefined ? s.model_id : existing.model_id;
          existing.project = s.project || existing.project || '';
          existing.project_repo = s.project_repo || existing.project_repo || '';
          existing.unreadCount = s.unread_count || 0;
          // Restore tool activity text from server (persists across reloads)
          if (s.activity) {
            existing.toolStatusText = s.activity;
          }
          // Pre-populate activity log so thinking indicator shows full history on reconnect
          if (s.activity_log && s.activity_log.length > 0 && typeof _activityLogStore !== 'undefined') {
            _activityLogStore.set(s.session_id, { texts: s.activity_log.slice() });
          }
          // Restore session state from server's canonical state field
          const serverState = s.state;
          if (serverState) {
            existing.compacting = (serverState === 'compacting');
            setSessionSidebarState(s.session_id, serverState);
            // Keep sessionState in sync so getSessionState() / switchTab indicator check is correct
            if (['processing', 'compacting'].includes(serverState)) {
              existing.sessionState = 'processing';
            } else if (serverState === 'idle') {
              existing.sessionState = 'idle';
            }
            // Restore typing indicator immediately for the active session (reconnect — switchTab won't be called)
            if (s.session_id === activeSessionId) {
              const indicatorActive = ['processing', 'compacting', 'starting'].includes(serverState);
              if (indicatorActive) {
                if (typeof showTypingIndicator === 'function') showTypingIndicator(s.session_id);
              } else {
                if (typeof hideTypingIndicator === 'function') hideTypingIndicator(s.session_id);
              }
            }
          }
        }
      }
    }
    Promise.all(promises).then(() => {
      _sessionsLoading = false;
      document.getElementById('sidebar')?.classList.remove('loading');
      _flushMessageBuffer();
      renderVoiceGridIfActive();
      renderSidebar();
      startOpenClawPolling();
      // Push saved speed from localStorage to server for all sessions
      const savedSpd = localStorage.getItem('hub_speed');
      if (savedSpd) {
        const spd = parseFloat(savedSpd);
        for (const [sid, s] of sessions) {
          if ((s.speed || 1.0) !== spd) {
            s.speed = spd;
            fetch(`/api/sessions/${sid}/speed`, {
              method: 'PUT',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ speed: spd }),
            }).catch(e => console.warn('speed sync:', e));
          }
        }
      }
      // Auto-restore previously active session on reconnect (skip if a group chat is active)
      if (!activeSessionId && !activeGroupId) {
        try {
          // Try direct session ID first (OpenClaw sessions)
          const savedSession = (() => { try { return localStorage.getItem('hub_active_session'); } catch(e) { return null; } })();
          if (savedSession && sessions.has(savedSession)) {
            switchTab(savedSession);
          }
          // Then try voice lookup (voice agents)
          if (!activeSessionId) {
            const savedVoice = (() => { try { return localStorage.getItem('hub_active_voice'); } catch(e) { return null; } })();
            if (savedVoice) {
              for (const [sid, s] of sessions) {
                if (s.voice === savedVoice) {
                  switchTab(sid);
                  break;
                }
              }
            }
          }
          // Fallback: if still no active session and only one session, auto-select it
          if (!activeSessionId && sessions.size === 1) {
            const [sid] = sessions.keys();
            switchTab(sid);
          }
        } catch(e) {}
      }
    }).catch((e) => {
      console.error('[session_list] Promise.all failed:', e);
      _sessionsLoading = false;
      document.getElementById('sidebar')?.classList.remove('loading');
      _flushMessageBuffer();
      renderSidebar();
    });
    return;
  }
  if (type === 'session_spawned') {
    if (!sessions.has(data.session.session_id)) {
      addSession(data.session, false).then(() => {
        renderVoiceGridIfActive();
        if (data.session.backend === 'openclaw') fetchOpenClawAgents();
      });
    }
    return;
  }
  if (type === 'session_terminated') {
    removeSession(data.session_id);
    fetchOpenClawAgents();
    return;
  }
  if (type === 'user_notification') {
    const level = data.level || 'info';
    const title = data.title || '';
    const msg = data.message || '';
    const text = title ? `${title}: ${msg}` : msg;
    if (typeof showToast === 'function') {
      showToast(text, level);
    } else {
      // Fallback: browser notification or console
      console.info(`[notify] ${text}`);
    }
    return;
  }

  if (type === 'groupchat_created' || type === 'groupchat_updated') {
    const g = data.group;
    if (g) { groupChats.set(g.name.toLowerCase(), g); renderSidebar(); }
    return;
  }
  if (type === 'groupchat_deleted') {
    groupChats.delete((data.name || '').toLowerCase());
    if (activeGroupId === data.group_id) { activeGroupId = null; showWelcome(); }
    renderSidebar();
    return;
  }
  if (type === 'groupchat_message') {
    // Update group chat view if it's currently open
    if (activeGroupId === data.group_id && typeof appendGroupChatMessage === 'function') {
      appendGroupChatMessage(data.message);
    }
    return;
  }
  if (type === 'group_outbound') {
    // Show outbound group message in the sender's chat
    if ((showAgentMessages) && sessions.has(data.session_id)) {
      addMessage(data.session_id, 'system', `[Group msg to ${data.group_name}] ${data.text}`, { id: data.msg_id });
    }
    return;
  }
  if (type === 'groupchat_ack') {
    if (activeGroupId === data.group_id && typeof appendGroupChatMessage === 'function') {
      appendGroupChatMessage({ bare_ack: true, parent_id: data.msg_id, id: data.ack_id, sender: data.sender || 'You', sender_voice: data.sender_voice || '' });
    }
    return;
  }
  if (type === 'project_deleted') { loadProjects(); return; }
  if (type === 'project_renamed') {
    // If slug changed and it was the active folder, track new slug
    if (data.old_slug && data.slug && data.old_slug !== data.slug && currentProject === data.old_slug) {
      currentProject = data.slug;
    }
    loadProjects();
    return;
  }
  if (type === 'project_switched') {
    currentProject = data.project || 'default';
    const sel = document.getElementById('project-selector');
    if (sel) sel.value = currentProject;
    loadProjects().then(() => {
      // Auto-switch to first running agent in the new project
      const projectVoices = currentProjectVoices || Object.keys(VOICE_NAMES);
      for (const v of projectVoices) {
        for (const [sid, s] of sessions) {
          if (s.voice === v) { switchTab(sid, true); return; }
        }
      }
      // No running agents — deselect
      if (activeSessionId) switchTab(null);
    });
    return;
  }
  if (type === 'session_status') {
    const s = sessions.get(data.session_id);
    if (s) {
      // Update activity and tool_name
      if ('activity' in data) {
        s.toolStatusText = data.activity || '';
      }
      if ('tool_name' in data) {
        s.toolName = data.tool_name || '';
      }
      if ('walking_mode' in data) {
        s.walking_mode = data.walking_mode;
        if (data.session_id === activeSessionId && typeof setToggle === 'function') {
          setToggle('walking_mode', data.walking_mode);
        }
      }
      if ('backend' in data && data.backend != null) s.backend = data.backend;
      if ('model_id' in data) {
        s.model_id = data.model_id;
        if (data.session_id === activeSessionId) {
          if (typeof updateModelLabel === 'function') updateModelLabel();
          if (typeof updateEffortLabel === 'function') updateEffortLabel();
        }
      }
      // Use canonical state field
      const serverState = data.state;
      if (serverState) {
        s.compacting = (serverState === 'compacting');
        setSessionSidebarState(data.session_id, serverState);
        // Typing indicator
        const isActive = ['processing', 'compacting', 'starting'].includes(serverState);
        if (isActive) {
          if (typeof showTypingIndicator === 'function') showTypingIndicator(data.session_id);
        } else {
          if (typeof hideTypingIndicator === 'function') hideTypingIndicator(data.session_id);
        }
      } else if (data.agent_idle) {
        // Legacy fallback: Stop hook without state field
        s.toolStatusText = '';
        setSessionSidebarState(data.session_id, 'idle');
        if (typeof hideTypingIndicator === 'function') hideTypingIndicator(data.session_id);
      }
      // Legacy status field (ready/starting)
      if (data.status === 'ready' && !data.silent) {
        cueSessionReady();
        addMessage(data.session_id, 'system', 'Connected.');
        // Remove "Connecting..." in minimal mode
        if (!activityVerbose) {
          const s = sessions.get(data.session_id);
          if (s) s.messages = s.messages.filter(m => m.id !== 'waiting-for-session-' + data.session_id);
          const waitEl = chatArea && chatArea.querySelector('[data-msg-id="waiting-for-session-' + data.session_id + '"]');
          if (waitEl) waitEl.remove();
        }
      }
      updateThinkingLabel(data.session_id);
    }
    renderSidebar();
    return;
  }
  if (type === 'project_status') {
    const s = sessions.get(data.session_id);
    if (s) {
      s.project = data.project || '';
      s.project_repo = data.project_repo || data.area || '';
      if ('role' in data) s.role = data.role || '';
      if ('task' in data) s.task = data.task || '';
    }
    renderSidebar();
    renderVoiceGridIfActive();
    updateHeaderProjectStatus();
    return;
  }
  if (type === 'compaction_status') {
    const s = sessions.get(data.session_id);
    if (s) {
      s.compacting = data.compacting;
      setSessionSidebarState(data.session_id, data.compacting ? 'compacting' : 'processing');
      renderSidebar();
    }
    return;
  }
  if (type === 'structured_event') {
    const s = sessions.get(data.session_id);
    if (!s) return;
    const isJsonBackend = s.backend === 'claude-json';
    const evType = data.event_type;
    if (evType === 'tool_use') {
      const toolName = data.tool_name || 'Tool';
      const toolData = data.data || {};
      // Build human-readable activity description
      let desc = toolName;
      if (toolName === 'Bash' && toolData.command) desc = `Running: ${toolData.command.slice(0, 60)}`;
      else if (toolName === 'Read' && toolData.file_path) desc = `Reading ${toolData.file_path.split('/').pop()}`;
      else if (toolName === 'Write' && toolData.file_path) desc = `Writing ${toolData.file_path.split('/').pop()}`;
      else if (toolName === 'Edit' && toolData.file_path) desc = `Editing ${toolData.file_path.split('/').pop()}`;
      else if (toolName === 'Glob' && toolData.pattern) desc = `Finding files: ${toolData.pattern}`;
      else if (toolName === 'Grep' && toolData.pattern) desc = `Searching for: ${toolData.pattern.slice(0, 40)}`;
      else if (toolName === 'Agent') desc = 'Spawning agent...';
      s.toolStatusText = desc;
      s.toolName = toolName;
      if (isJsonBackend) {
        // Claude-json: render tool card inline in chat
        if (typeof hideThinkingDecode === 'function') hideThinkingDecode(data.session_id);
        const toolId = 'tool-' + Date.now();
        s.messages.push({ role: 'tool', toolName, toolData, toolStatus: 'running', toolId, ts: Date.now() / 1000 });
        if (data.session_id === activeSessionId) {
          const card = createToolCardEl(s.messages[s.messages.length - 1]);
          chatArea.appendChild(card);
          chatScrollToBottom(false);
        }
      } else {
        if (typeof showTypingIndicator === 'function') showTypingIndicator(data.session_id);
        if (typeof _updateTypingIndicatorText === 'function') _updateTypingIndicatorText(data.session_id, desc);
      }
    } else if (evType === 'tool_result') {
      s.toolName = '';
      if (isJsonBackend) {
        // Mark last running tool as done
        for (let i = s.messages.length - 1; i >= 0; i--) {
          if (s.messages[i].role === 'tool' && s.messages[i].toolStatus === 'running') {
            s.messages[i].toolStatus = 'done';
            break;
          }
        }
        if (typeof updateToolCardStatus === 'function') updateToolCardStatus(data.session_id, 'success');
      }
    } else if (evType === 'thinking') {
      s.toolStatusText = 'Thinking...';
      s.toolName = '';
      if (isJsonBackend) {
        if (typeof showThinkingDecode === 'function') showThinkingDecode(data.session_id);
      } else {
        if (typeof showTypingIndicator === 'function') showTypingIndicator(data.session_id);
        if (typeof _updateTypingIndicatorText === 'function') _updateTypingIndicatorText(data.session_id, 'Thinking...');
      }
    } else if (evType === 'idle') {
      s.toolStatusText = '';
      s.toolName = '';
      if (isJsonBackend) {
        if (typeof hideThinkingDecode === 'function') hideThinkingDecode(data.session_id);
      } else {
        if (typeof hideTypingIndicator === 'function') hideTypingIndicator(data.session_id);
      }
    } else if (evType === 'compacting') {
      s.toolStatusText = 'Compacting context...';
      s.compacting = true;
      if (isJsonBackend) {
        if (typeof hideThinkingDecode === 'function') hideThinkingDecode(data.session_id);
        if (typeof showThinkingDecode === 'function') showThinkingDecode(data.session_id);
      } else {
        if (typeof showTypingIndicator === 'function') showTypingIndicator(data.session_id);
        if (typeof _updateTypingIndicatorText === 'function') _updateTypingIndicatorText(data.session_id, 'Compacting context...');
      }
    }
    renderSidebar();
    return;
  }
  if (type === 'error') {
    alert('Hub error: ' + data.message);
    return;
  }

  if (type === 'agent_message') {
    const msg = data.message;
    if (msg) {
      const senderName = (msg.sender_name || msg.sender || '?');
      const recipName = (msg.recipient_name || msg.recipient || '?');
      const sName = senderName.charAt(0).toUpperCase() + senderName.slice(1);
      const rName = recipName.charAt(0).toUpperCase() + recipName.slice(1);
      const isBareAck = msg.bare_ack || (msg.parent_id && !msg.content);
      const threadOpts = { id: msg.id || null, parentId: msg.parent_id || null, isBareAck };
      // Bare acks (thumbs-up) always show; other agent messages respect toggle
      // Show in recipient's chat
      if ((isBareAck || showAgentMessages) && sessions.has(msg.recipient)) {
        const text = isBareAck ? '' : `[Agent msg from ${sName}] ${msg.content || ''}`;
        addMessage(msg.recipient, 'system', text, threadOpts);
      }
      // Show in sender's chat (skip if same as recipient to avoid double-counting)
      if (msg.sender !== msg.recipient && (isBareAck || showAgentMessages) && sessions.has(msg.sender)) {
        const text = isBareAck ? '' : `[Agent msg to ${rName}] ${msg.content || ''}`;
        addMessage(msg.sender, 'system', text, threadOpts);
      }
    }
    return;
  }

  if (type === 'user_ack') {
    // User acknowledged a message — add bare ack to the session's message list
    const sid = data.session_id;
    if (sid && data.msg_id) {
      addMessage(sid, 'system', '', { id: data.ack_id || null, parentId: data.msg_id, isBareAck: true });
    }
    return;
  }

  // Session-scoped messages
  if (!session_id) return;
  const s = sessions.get(session_id);
  if (!s) return;

  if (type === 'activity_text') {
    addMessage(session_id, 'activity', data.text);
    return;
  }
  if (type === 'assistant_text') {
    // Don't call hideTypingIndicator here — addMessage removes it atomically with the new message
    // to prevent a two-step DOM jump (indicator removal + message addition in separate frames)
    const msgId = data.msg_id || null;

    // Streaming delta (OpenClaw): update message in place
    if (data.streaming && msgId && data.text) {
      const s = sessions.get(session_id);
      if (!s) return;
      const existing = s.messages.find(m => m.id === msgId);
      if (existing) {
        existing.text = data.text;
        // Replace DOM element with properly rendered version (markdown, styling)
        if (session_id === activeSessionId) {
          const el = chatArea.querySelector(`[data-msg-id="${CSS.escape(msgId)}"]`);
          if (el) {
            const vc = s.backend === 'openclaw' ? '#2ecc71' : voiceColor(s.voice);
            const newEl = createMsgEl('assistant', data.text, vc, s.voice, existing);
            el.replaceWith(newEl);
          }
        }
      } else {
        s.messages.push({ role: 'assistant', text: data.text, id: msgId, ts: Date.now() / 1000, streaming: true });
        if (session_id === activeSessionId) renderChat(true);
      }
      return;
    }

    // Non-streaming final: remove any streaming preview for this session
    const s = sessions.get(session_id);
    if (s) {
      const hadStreaming = s.messages.some(m => m.streaming);
      if (hadStreaming) {
        s.messages = s.messages.filter(m => !m.streaming);
      }
    }

    if (data.fire_and_forget) {
      // Fire-and-forget speak: just add message to chat, don't change state
      if (data.text && data.text.trim()) {
        addMessage(session_id, 'assistant', data.text, { id: msgId });
      }
      if (session_id !== activeSessionId) {
        markSessionUnread(session_id);
      } else {
        clearSessionUnread(session_id);
      }
    } else {
      // Converse-driven response: transition to listening state
      setSessionState(session_id, 'listening');
      if (data.text && data.text.trim()) {
        addMessage(session_id, 'assistant', data.text, { id: msgId });
      }
      if (session_id !== activeSessionId) {
        markSessionUnread(session_id);
      } else {
        clearSessionUnread(session_id);
      }
    }
  } else if (type === 'user_text') {
    if (!data.text || !data.text.trim()) return;  // Skip blank user messages
    addMessage(session_id, 'user', data.text, { id: data.msg_id || null });
    // Don't set processing here — wait for the agent's hook events (PreToolUse)
    // to signal actual processing. Setting it here causes false "thinking" state
    // when messages fail to deliver or the agent hasn't picked them up yet.
  } else if (type === 'audio') {
    setSessionState(session_id, 'speaking');
    if (session_id === activeSessionId) {
      // Setup karaoke spans on DOM and get words with el references (DOM is rendered for active session)
      const karaokeWords = (data.words && data.words.length)
        ? karaokeSetupMessage(session_id, data.words, data.msg_id)
        : null;
      enqueueAudio(session_id, data.data, karaokeWords, data.msg_id);
      setStatus('Speaking...', session_id);
    } else {
      // Buffer audio as rich object — words and msgId preserved for karaoke on tab switch
      s.statusText = 'Speaking...';
      if (!s.audioBuffer) s.audioBuffer = [];
      s.audioBuffer.push({ data: data.data, words: data.words || null, msgId: data.msg_id || null });
    }
  } else if (type === 'listening') {
    // Show "ready" indicator on first idle transition (startup)
    if (data.state === 'idle' && s.sidebarState === 'starting') {
      // Remove "Connecting..." placeholder
      if (s) s.messages = (s.messages || []).filter(m => m.id !== 'waiting-for-session-' + session_id);
      const waitEl = chatArea && chatArea.querySelector('[data-msg-id="waiting-for-session-' + session_id + '"]');
      if (waitEl) waitEl.remove();
      cueSessionReady();
      if (typeof addMessage === 'function') addMessage(session_id, 'system', '● ready');
    }
    // Defer transition to listening if audio is still playing (speak → wait race)
    const isPlaying = (currentAudio && currentAudio.sessionId === session_id) ||
                      (currentBufferedPlayer && currentBufferedPlayer.sessionId === session_id) ||
                      (s.audioBuffer && s.audioBuffer.length > 0);
    if (isPlaying) {
      s.pendingListenAfterPlayback = true;
    } else {
      setSessionState(session_id, 'listening');
      _handleListeningUI(session_id, s);
    }
  } else if (type === 'thinking') {
    setSessionState(session_id, 'processing');
  } else if (type === 'status') {
    s.statusText = data.text;
    if (session_id === activeSessionId) setStatus(data.text, session_id);
    else renderSidebar();
  } else if (type === 'done') {
    const isPlaying = (currentAudio && currentAudio.sessionId === session_id) ||
                      (currentBufferedPlayer && currentBufferedPlayer.sessionId === session_id) ||
                      (s.audioBuffer && s.audioBuffer.length > 0);
    if (isPlaying) {
      setSessionState(session_id, 'speaking');
    } else {
      setSessionState(session_id, 'idle');
    }
  } else if (type === 'session_ended') {
    // Agent said goodbye — auto-close after a short delay
    addMessage(session_id, 'system', 'Session ended.');
    setTimeout(() => terminateSession(session_id), 3000);
  } else if (type === 'inbox_update') {
    // v0.6.0: inbox message count update
    s.inboxCount = data.count || 0;
    s.inboxPreview = data.latest ? data.latest.preview : '';
    renderSidebar();
  }
}
