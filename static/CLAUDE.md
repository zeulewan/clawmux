# Frontend Module

The `static/` directory contains the ClawMux browser UI — a vanilla JavaScript single-page application with no frameworks. All DOM manipulation is direct.

## Files

### `hub.html` (~3100 lines)
The main SPA. Contains:
- **CSS** (~1300 lines) — Full theme system with CSS variables, dark/light mode via `prefers-color-scheme`, responsive mobile layout. Key variables: `--bg`, `--text`, `--blue`, `--green`, `--radius`, `--voice-color`.
- **HTML structure** — Header, sidebar, main content (voice grid, chat area, controls, settings, notes panel).
- **Inline JS** (~1400 lines) — DOM refs, `switchTab()`, `addSession()`, session spawning, settings management, keyboard shortcuts, focus mode, debug panel, context menus, `setSessionState()`, thinking sounds, transport controls.

### `js/state.js`
Global shared state variables used by all modules:
- `sessions` (Map) — session_id → session object with messages, state, voice, etc.
- `activeSessionId` — Currently viewed session
- `ws` — WebSocket connection
- Audio state: `currentAudio`, `currentBufferedPlayer`, `playbackPaused`, `pausedBuffer`
- Recording state: `recording`, `micMuted`, `autoMode`, `vadEnabled`
- UI toggles: `ttsEnabled`, `sttEnabled`, `showAgentMessages`, `thinkingSoundsEnabled`

### `js/ws.js`
WebSocket connection and message routing:
- `connect()` — Opens WS, handles reconnect with 2s backoff
- `handleMessage(data)` — Routes all WS message types: `session_list`, `session_status`, `assistant_text`, `user_text`, `audio`, `listening`, `thinking`, `agent_message`, `user_ack`, `inbox_update`, etc.
- `_reconnectSyncSession()` — Cursor-based reconnect: fetches only messages after last known ID via `?after=<msg_id>`
- Message buffering during session loading (`_sessionsLoading`, `_messageBuffer`)

### `js/audio.js` (~1600 lines)
Audio recording and playback:
- **Recording** — `startRecording()`, `stopRecording()` using MediaRecorder API. Persistent mic stream acquired once.
- **Playback** — Buffered streaming via Web Audio API. `enqueueAudio()` decodes base64 audio and plays with word-level karaoke highlighting.
- **Karaoke** — Word timestamps from TTS are mapped to `<span>` elements. Active word gets `.active` class. Supports pause, resume, and arrow-key scrubbing.
- **VAD** — Voice Activity Detection for auto-end recording and auto-interrupt during playback.
- **Transport** — Pause/resume/scrub controls. `transportPause()`, `transportResume()`, `transportRestart()`.
- **Waveform** — Canvas-based real-time waveform visualization during recording.

### `js/chat.js`
Message rendering and chat interaction:
- `addMessage(sessionId, role, text, opts)` — Append a message to the session store and DOM. Deduplicates by message ID. Roles: `user`, `assistant`, `system`, `activity`.
- `renderChat()` — Full re-render (used on tab switch). Lazy loads last 50 messages, virtual scrolling with load-more on scroll-to-top.
- `createMsgEl()` — Creates message DOM elements with markdown rendering (marked.js), syntax highlighting (highlight.js), KaTeX math, copy buttons, ack buttons, inter-agent message collapsing.
- Text input mode — `cycleInputMode()` toggles voice/typing. Text sent via WebSocket as `text` or `interjection` type.
- Drag-and-drop file upload to chat area.
- Long-press context menu on mobile.

### `js/sidebar.js`
Sidebar agent list:
- `renderSidebar()` — Renders agent cards with state indicators (colored dot: idle=green, working=animated blue, speaking=animated purple, starting=yellow).
- `voiceColor()`, `voiceDisplayName()` — Voice ID to color/name mapping.
- Drag-to-reorder agents, unread badges, context menu (terminate, change model).
- Voice grid view for multi-agent overview.
- Settings panel rendering and toggle management.

### `js/notes.js`
Per-session scratch notes panel:
- Auto-saves to `localStorage`
- Collapsible side panel
- Per-session content (switches with active tab)

## Script Load Order

```
state.js → ws.js → (inline DOM refs) → audio.js → sidebar.js → chat.js → notes.js → (inline main)
```

All modules are global (window-scoped). Dependencies between modules are documented in comment headers at the top of each file.

## Communication with Backend

### WebSocket Messages (browser → hub)
- `{type: "audio", session_id, data}` — Voice recording (base64)
- `{type: "text", session_id, text}` — Text message (when agent is listening)
- `{type: "interjection", session_id, text}` — Text while agent is working
- `{type: "user_ack", session_id, msg_id}` — Thumbs-up acknowledgment
- `{type: "set_mode", session_id, mode}` — Input mode change (voice/text)
- `{type: "playback_done", session_id}` — Audio playback finished

### WebSocket Messages (hub → browser)
- `session_list` — All sessions on connect
- `session_status` — State/status_text updates (from hooks)
- `assistant_text` — Agent spoke (with optional `fire_and_forget`)
- `user_text` — User message echo (for chat display)
- `audio` — TTS audio data (base64) with word timestamps
- `listening` — Agent is waiting for input
- `agent_message` — Inter-agent message (for chat display)
- `inbox_update` — Inbox count changed

### REST API Calls (browser → hub)
- `GET /api/history/{voice_id}` — Full history on load, cursor-based on reconnect
- `GET /api/settings` — Restore persisted settings
- `POST /api/sessions/{id}/spawn` — Spawn agent
- `POST /api/sessions/{id}/terminate` — Kill agent
- `POST /api/sessions/{id}/viewing` — Track which session is active (for unread)
- `PUT /api/sessions/{id}/speed` — Set TTS speed
- `PUT /api/sessions/{id}/model` — Change Claude model

## DOM Update Patterns

- **Append-only** — `addMessage()` creates one DOM element and appends it. No periodic re-renders or polling.
- **Dedup by ID** — Messages with duplicate IDs are silently skipped.
- **Full render on tab switch** — `renderChat()` clears and rebuilds when switching between agent tabs.
- **Lazy loading** — Shows last 50 messages (`_CHAT_BATCH`), loads 50 more on scroll-to-top, unloads back to 50 on scroll-to-bottom (max DOM: 150 `_CHAT_MAX_DOM`).
