# Architecture Refactor — Implementation Plan

*Created: 2026-03-04*
*Companion to: [refactor.md](refactor.md) (Nova's brief)*

Actionable extraction plan for splitting `hub.py` (1,819 lines) and `hub.html` (5,607 lines) into focused modules. Each phase is independently deployable.

---

## Safety & Testing Strategy

1. **One module at a time.** Extract, test, commit. Never refactor two modules in parallel.
2. **Python: FastAPI routers.** Move routes into a router, import the router in `hub.py`. Import errors surface immediately on startup — no silent breakage.
3. **JS: Use the `working` git tag as safety net.** Diff against it if anything breaks.
4. **Incremental extraction only.** No logic changes — just moving functions between files. Logic improvements come after the refactor.
5. **Test checklist after each extraction:**
   - Hub starts without errors (`python -m server.hub`)
   - Browser loads without console errors
   - Voice send/receive works (record → transcribe → TTS playback)
   - Sidebar updates (state dots, status text, project labels)
   - Messages appear in chat (user, agent, system, threaded replies)
6. **Thin shells.** After refactor, `hub.py` and `hub.html` become entry points that import everything. Easy to inline back if needed.
7. **No logic changes during refactor.** Just file reorganization. Logic improvements are a separate effort.

---

## Phase 1: Extract `ws.js` — WebSocket Connection

**Goal:** Move the WebSocket connection, reconnection, and message dispatch out of `hub.html`.

### What moves to `static/js/ws.js`

| Lines | Function / Block | Description |
|-------|-----------------|-------------|
| 1475 | `let ws = null` | WebSocket reference |
| 3665–3735 | `connect()` | WS open/close/error/message handlers |
| 3737–3738 | `_sessionsLoading`, `_messageBuffer` | Session loading gate |
| 3740–3830 | `_refreshHistory()`, `startHistorySync()` | History sync on reconnect |
| 3832–4570 | `handleMessage(data)` | Main message dispatcher (all `data.type` cases) |

### Exports from `ws.js`

```javascript
export { connect, ws, sendWS, onMessage };
```

### Imports into `ws.js`

Needs access to: `sessions`, `activeSessionId`, `setConnected`, `setStatus`, `addMessage`, `renderSidebar`, `showThinking`, `hideThinking`, `updateTransportBar`, `switchTab`, `addSession`, `removeSession`.

These come from other modules (sidebar.js, chat.js, audio.js) via imports, or from a shared `state.js` module (see Phase 2).

### Shared state module: `static/js/state.js`

Extract global state that multiple modules read/write:

| Lines | Variable | Used by |
|-------|----------|---------|
| 1471 | `sessions` (Map) | ws, chat, sidebar, audio |
| 1473 | `activeSessionId` | ws, chat, sidebar, audio |
| 1474 | `recordingSessionId` | audio |
| 1478 | `recording` | audio, sidebar |
| 1479 | `micMuted` | audio |
| 1480 | `autoMode` | audio |
| 1482–1500 | VAD/playback/transport state | audio |
| 1491 | `spawningVoices` | sidebar |
| 1494–1495 | `voiceResponsesEnabled`, `showAgentMessages` | chat, settings |

`state.js` exports mutable references. All modules import from it.

---

## Phase 2: Extract `audio.js` — Recording, Playback, VAD

**Goal:** Move all audio I/O (mic, TTS playback, VAD, transport controls) into one module.

### What moves to `static/js/audio.js`

| Lines | Function / Block | Description |
|-------|-----------------|-------------|
| 1525–1620 | `startWaveform()`, `drawWaveform()`, `stopWaveform()` | Mic waveform visualization |
| 1626–1665 | `playTone()`, `cueListening()`, `cueProcessing()`, `cueSessionReady()` | Audio cue sounds |
| 2172–2245 | `stopActiveAudio()` | Stop current TTS playback |
| 2346–2430 | `playMessageTTS()`, `_wrapWordsInSpans()`, `_wrapTextNodesInKaraokeSpans()` | TTS playback with karaoke |
| 3186–3234 | `startVAD()` | Silence detection during recording |
| 3255–3425 | `updateTransportBar()`, `transportPause()`, `transportNext()`, `transportPrev()` | Transport bar controls |
| 3381–3500 | `startPlaybackVAD()`, `stopPlaybackVAD()`, `startThinkingVAD()`, `stopThinkingVAD()` | VAD during playback/thinking |
| 3507–3560 | `showThinking()`, `updateThinkingLabel()`, `hideThinking()` | Thinking indicator |
| 4576–4610 | `updateMicUI()` | Mic button state |
| 4608–4760 | `getMicStream()`, `startRecording()`, `stopRecording()`, `cancelRecording()`, `sendAudio()`, `_flushPendingAudio()`, `sendSilentAudio()` | Recording pipeline |
| 4759–4870 | `interruptPlayback()`, `pttStart()`, `pttEnd()`, `_isTextTarget()` | Push-to-talk, interrupt |

### Exports from `audio.js`

```javascript
export {
  startRecording, stopRecording, cancelRecording, sendAudio,
  playMessageTTS, stopActiveAudio, interruptPlayback,
  updateTransportBar, transportPause, transportNext, transportPrev,
  startWaveform, stopWaveform, updateMicUI, getMicStream,
  showThinking, hideThinking, updateThinkingLabel,
  startPlaybackVAD, stopPlaybackVAD, startThinkingVAD, stopThinkingVAD,
  cueListening, cueProcessing, cueSessionReady,
  pttStart, pttEnd,
};
```

---

## Phase 3: Extract `sidebar.js` — Agent Cards & State Machine

**Goal:** Move sidebar rendering and introduce the state machine for agent status.

### What moves to `static/js/sidebar.js`

| Lines | Function / Block | Description |
|-------|-----------------|-------------|
| 1707–1718 | `voiceDisplayName()`, `voiceColor()`, `voiceIcon()`, `hexToRgba()` | Voice metadata helpers |
| 1719–1730 | `setConnected()` | Connection state indicator |
| 1732–1760 | `setStatus()`, `updateHeaderProjectStatus()` | Header status display |
| 1763–1860 | `updateLayout()`, `showWelcome()`, `showVoiceGrid()`, `switchToFocus()`, `exitFocusMode()`, `toggleSidebarExpand()`, `collapseSidebar()` | Layout mode switching |
| 1864–1935 | `setSessionSidebarState()`, `markSessionUnread()`, `clearSessionUnread()`, `_sidebarState()` | Per-session sidebar state |
| 1936–2170 | `_updateSidebarCard()`, `renderSidebar()`, `reorderSidebarVoice()` | Card rendering, drag-and-drop reorder |

### State machine (new logic — Phase 3 only exception to "no logic changes")

Replace `sidebarState` string + scattered boolean checks with a formal state machine:

```javascript
// static/js/sidebar.js
const AgentState = {
  IDLE: 'idle',
  LISTENING: 'listening',
  PROCESSING: 'processing',
  SPEAKING: 'speaking',
  WAITING: 'waiting',    // in clawmux wait
  COMPACTING: 'compacting',
  SPAWNING: 'spawning',
  OFFLINE: 'offline',
};

const TRANSITIONS = {
  idle:       ['listening', 'processing', 'waiting', 'compacting', 'offline'],
  listening:  ['processing', 'idle', 'offline'],
  processing: ['speaking', 'idle', 'waiting', 'compacting', 'offline'],
  speaking:   ['idle', 'listening', 'processing', 'offline'],
  waiting:    ['processing', 'idle', 'offline'],
  compacting: ['idle', 'processing', 'offline'],
  spawning:   ['idle', 'offline'],
  offline:    ['idle', 'spawning'],
};
```

**Note:** The state machine is the one exception to "no logic changes" — it replaces the existing sidebar state derivation with an equivalent but explicit model. The transition table must match all existing `setSessionSidebarState()` call sites exactly.

---

## Phase 4: Extract `chat.js` — Message Rendering

**Goal:** Move chat message creation, markdown rendering, and message list management.

### What moves to `static/js/chat.js`

| Lines | Function / Block | Description |
|-------|-----------------|-------------|
| 1502–1510 | `chatArea` ref, `chatScrollToBottom()` | Chat scroll management |
| 2439–2565 | `_wrapTextNodesInKaraokeSpans()`, `_renderMarkdown()` | Markdown + KaTeX rendering |
| 2566–2610 | `createMsgEl()` | Message DOM element creation |
| 2612–2688 | `renderChat()`, `_debugBanner()` | Full chat re-render |
| 2689–2710 | `addMessage()` | Add single message to session |
| 5265–5340 | `cycleInputMode()`, `applyInputMode()`, `sendTextMessage()`, `pasteFromClipboard()` | Text input handling |
| 5344–5410 | `handleMsgPointerDown()`, `handleMsgPointerUp()`, `showCopyToast()`, `saveInputMode()`, `restoreInputMode()` | Message interactions |

### Exports from `chat.js`

```javascript
export {
  addMessage, renderChat, createMsgEl, chatScrollToBottom,
  sendTextMessage, cycleInputMode, applyInputMode,
};
```

---

## Phase 5: Split `hub.py` into Python Modules

**Goal:** Break the 1,819-line server into focused modules using FastAPI routers.

### Module: `server/routes.py` — REST API Endpoints

| Lines | Function | Endpoint |
|-------|----------|----------|
| 504–520 | `index()`, `static_file()` | `GET /`, `GET /static/{filename}` |
| 1015–1050 | `list_sessions()`, `spawn_session()` | `GET/POST /api/sessions` |
| 1044–1085 | `terminate_session()`, `shutdown_hub()` | `DELETE /api/sessions/{id}`, `POST /api/shutdown` |
| 1085–1110 | `set_session_voice()`, `set_session_speed()` | `PUT /api/sessions/{id}/voice`, `PUT /api/sessions/{id}/speed` |
| 1111–1200 | `list_projects()` through `delete_project()` | `/api/projects/*` |
| 1206–1260 | `get_history()`, `clear_history()`, `mark_session_read()`, `set_viewing_session()` | `/api/history/*`, `/api/sessions/{id}/mark-read`, `/api/sessions/{id}/viewing` |
| 1587–1650 | `get_settings()`, `update_settings()`, `_load_settings()`, `_save_settings()` | `/api/settings` |
| 1649–1675 | `get_usage()`, `get_context()` | `/api/usage`, `/api/context` |
| 1673–1790 | `debug_info()`, `debug_log()` | `/api/debug`, `/api/debug/log` |

**Total: ~500 lines → `routes.py`**

### Module: `server/voice.py` — TTS/STT Pipeline

| Lines | Function | Description |
|-------|----------|-------------|
| 198–245 | `strip_non_speakable()` | Text cleanup for TTS |
| 247–310 | `tts()`, `tts_captioned()` | Kokoro TTS generation |
| 309–415 | `_strip_prefix_audio()`, `_get_stt_prompt()` | Audio post-processing |
| 415–440 | `stt()` | Whisper STT transcription |
| 1538–1585 | `transcribe_audio()`, `text_to_speech()`, `text_to_speech_captioned()` | REST wrappers (`/api/transcribe`, `/api/tts`, `/api/tts-captioned`) |

**Total: ~250 lines → `voice.py`**

### Module: `server/websocket.py` — WebSocket Handlers

| Lines | Function | Description |
|-------|----------|-------------|
| 523–660 | `browser_websocket()`, `handle_browser_message()` | Browser `/ws` handler |
| 658–725 | `wait_websocket()` | Agent `/ws/wait/{session_id}` handler |
| 725–803 | `mcp_websocket()` | MCP `/mcp/{session_id}` handler |

**Total: ~300 lines → `websocket.py`**

> **Note on circular dependencies:** `send_to_browser()`, `_flush_browser_queue()`, `browser_ws`, and `browser_queue` stay in `hub.py` as shared infrastructure. Both `websocket.py` and `messaging.py` import them from hub — this avoids a circular dependency where messaging needs to push browser notifications and websocket handlers need to call messaging functions.

### Module: `server/messaging.py` — Send, Inbox, Hooks

| Lines | Function | Description |
|-------|----------|-------------|
| 820–870 | `_session_from_cwd()`, `_tool_status_text()` | Hook helpers |
| 872–890 | `_format_inbox_messages()` | Inbox message formatting |
| 889–1015 | `hook_tool_status()` | `/api/hooks/tool-status` (PreToolUse/PostToolUse handler) |
| 1256–1350 | `_resolve_session()`, `send_message()` | `/api/messages/send` |
| 1351–1420 | `speak_to_user()` | `/api/messages/speak` (TTS fire-and-forget) |
| 1419–1470 | `ack_message()`, `reply_to_message()` | `/api/messages/{id}/ack`, `/api/messages/{id}/reply` |
| 1454–1510 | `list_messages()`, `get_message()`, `get_inbox()`, `peek_inbox()` | Inbox/message queries |
| 1511–1538 | `_inbox_write_and_notify()` | Inbox write + WS push |

**Total: ~450 lines → `messaging.py`**

### What stays in `hub.py` (~310 lines)

| Lines | Function | Description |
|-------|----------|-------------|
| 1–58 | Imports, constants, globals | App-wide state |
| 59–65 | `_hist_prefix()`, `_gen_msg_id()` | Shared helpers |
| 84–125 | `_flush_browser_queue()`, `send_to_browser()` | Browser WS send helpers (shared by websocket.py + messaging.py) |
| 128–195 | `heartbeat_loop()`, `compaction_monitor_loop()` | Background tasks |
| 442–503 | `lifespan()` | App startup/shutdown lifecycle |
| 1789–1819 | `_log_sigterm()`, `__main__` block | Process signal handling |

Plus: FastAPI app creation, middleware, router imports, and module wiring.

### Integration pattern

```python
# server/hub.py (after refactor)
from fastapi import FastAPI
from server.routes import router as routes_router
from server.messaging import router as messaging_router
from server.voice import router as voice_router
from server.websocket import register_ws_handlers

app = FastAPI(lifespan=lifespan)
app.include_router(routes_router)
app.include_router(messaging_router)
app.include_router(voice_router)
register_ws_handlers(app)  # WS endpoints need app directly
```

Shared state (`sessions`, `browser_ws`, `browser_queue`, `message_broker`) lives in `hub.py` and is imported by submodules.

---

## Phase 6: Cleanup

After all extractions are verified:

1. **Remove legacy code** — Delete deprecated CLI handlers, unused converse references, dead imports
2. **Update imports** — Ensure no circular dependencies between Python modules
3. **Cache busting** — Add version query params to JS module imports in hub.html: `<script type="module" src="js/ws.js?v=0.7.0">`
4. **hub.html becomes a shell** — HTML structure, CSS (lines 8–1184), `<script type="module">` imports, and DOM init (~100 lines of JS)

---

## Execution Order

| Phase | Module | Est. Lines Moved | Risk | Dependency |
|-------|--------|-------------------|------|------------|
| 1 | `state.js` + `ws.js` | ~200 | Low | None — first extraction |
| 2 | `audio.js` | ~600 | Medium | Needs `state.js` |
| 3 | `sidebar.js` + state machine | ~450 | Medium | Needs `state.js`, `ws.js` |
| 4 | `chat.js` | ~350 | Low | Needs `state.js` |
| 5a | `server/voice.py` | ~250 | Low | No other module deps |
| 5b | `server/routes.py` | ~500 | Low | Needs shared state from hub |
| 5c | `server/websocket.py` | ~350 | Medium | Needs messaging, voice |
| 5d | `server/messaging.py` | ~450 | Medium | Needs websocket for push |
| 6 | Cleanup | ~0 (deletions) | Low | All phases complete |

**Total: ~3,150 lines moved out of the two monoliths.**

After refactor:
- `hub.html`: ~1,300 lines (HTML + CSS shell, ~100 lines init JS)
- `hub.py`: ~270 lines (app wiring, lifecycle, background tasks)
- 4 JS modules: ~1,600 lines total
- 4 Python modules: ~1,550 lines total
