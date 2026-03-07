# Hub Split Plan

Split the two largest files — `server/hub.py` (2,011 lines) and `static/js/audio.js` (1,791 lines) — into focused modules.

---

## Part 1: `server/hub.py` Split

### Current state

`hub.py` is a monolith handling: app setup, lifespan, background loops, browser WS, wait WS, hook processing, HTTP routes (sessions, projects, agents, messages, inbox, notes, settings, usage, debug), and helper functions.

### Target structure

| New file | Lines (est.) | What moves there |
|----------|-------------:|-----------------|
| `routes.py` | ~700 | All `@app.get/post/put/delete` HTTP endpoints |
| `websockets.py` | ~250 | `browser_websocket()`, `wait_websocket()`, `handle_browser_message()`, `send_to_browser()`, `_flush_browser_queue()` |
| `hooks.py` | ~200 | `hook_tool_status()`, `_tool_activity_text()`, `_format_inbox_messages()`, `_inbox_write_and_notify()` |
| `hub.py` (slimmed) | ~500 | App creation, lifespan, background loops, shared state, imports |

### Function assignments

#### `routes.py`
All HTTP route handlers, grouped by domain:

- **Sessions:** `list_sessions`, `spawn_session`, `terminate_session`, `restart_session`, `upload_file`, `set_project_status`, `mark_session_read`, `set_viewing_session`, `set_session_voice`, `set_session_speed`
- **Projects:** `list_projects`, `create_project`, `copy_project_history`, `activate_project`, `reorder_voices`, `rename_project`, `delete_project`
- **Agents:** `list_agents`, `get_agent`, `update_agent`, `assign_agent`, `regenerate_all_templates`, `regenerate_template`
- **Messages:** `send_message`, `speak_to_user`, `ack_message`, `reply_to_message`, `list_messages`, `get_message`
- **Inbox:** `get_inbox`, `peek_inbox`
- **History:** `get_history`, `clear_history`
- **Settings:** `get_settings`, `update_settings`, `_load_settings`, `_save_settings`
- **Notes:** `get_notes`, `update_notes`
- **Services:** `services_status`, `_load_whisper_model`
- **Usage:** `get_usage`, `get_context`, `_load_usage_sidecar`, `_save_usage_sidecar`, `_get_fallback_usage`
- **Debug:** `debug_info`, `debug_log`, `get_debug_log`, `debug_log` (POST)
- **Shutdown:** `shutdown_hub`
- **Static:** `index`, `static_file`

Use `APIRouter` instances grouped by domain. Register them in `hub.py` via `app.include_router()`.

#### `websockets.py`
- `browser_websocket()` — browser WS at `/ws`
- `handle_browser_message()` — dispatches browser commands
- `wait_websocket()` — agent wait WS at `/ws/wait/{session_id}`
- `send_to_browser()` — broadcast to browser WS
- `_flush_browser_queue()` — drain queued browser messages

#### `hooks.py`
- `hook_tool_status()` — PreToolUse/PostToolUse/Notification handler at `/api/hooks/tool-status`
- `_tool_activity_text()` — compose human-readable tool description
- `_format_inbox_messages()` — format inbox messages for additionalContext
- `_inbox_write_and_notify()` — write to inbox + notify browser/wait WS

#### `hub.py` (remains)
- FastAPI app creation, CORS, static mount
- `lifespan()` — startup/shutdown
- Background loops: `heartbeat_loop`, `compaction_monitor_loop`, `context_poll_loop`, `usage_poll_loop`
- Shared state: `sm` (SessionManager), `broker` (MessageBroker), `history` (HistoryStore), `agents_store`, `project_mgr`, `browser_ws`, `browser_queue`
- Helper: `_on_session_death`, `_hist_prefix`, `_gen_msg_id`, `_save_activity`, `_session_from_cwd`, `_resolve_session`

### Shared state access

The main challenge is shared mutable state. These globals live in `hub.py` and are needed by all modules:

- `sm: SessionManager`
- `broker: MessageBroker`
- `history: HistoryStore`
- `agents_store: AgentsStore`
- `project_mgr: ProjectManager`
- `browser_ws: WebSocket | None`
- `browser_queue: asyncio.Queue`
- `log: logging.Logger`

**Approach:** Keep these as module-level globals in `hub.py`. Other modules import them:
```python
# routes.py
from hub import sm, broker, history, agents_store, send_to_browser
```

Or use a lightweight `HubState` container class to avoid circular imports:
```python
# hub_state.py (new, ~30 lines)
class HubState:
    sm: SessionManager = None
    broker: MessageBroker = None
    # ... populated during lifespan()

state = HubState()
```

---

## Part 2: `static/js/audio.js` Split

### Current state

`audio.js` handles: waveform visualization, audio cues, TTS playback, karaoke word highlighting, VAD (voice activity detection), recording, mic/speaker selection, transport controls, push-to-talk, session state management, and thinking sounds.

### Target structure

| New file | Lines (est.) | What moves there |
|----------|-------------:|-----------------|
| `recorder.js` | ~500 | Mic capture, recording, VAD, push-to-talk, mic/speaker selection |
| `player.js` | ~600 | TTS playback, audio queue, karaoke, transport controls, thinking sounds |
| `audio.js` (slimmed) | ~400 | Shared AudioContext, waveform, audio cues, session state, UI glue |

### Function assignments

#### `recorder.js`
- `getMicStream()`, `populateMicSelector()`, `changeMicDevice()`, `populateSpeakerSelector()`, `changeSpeakerDevice()`
- `startRecording()`, `stopRecording()`, `cancelRecording()`, `sendAudio()`, `_flushPendingAudio()`, `sendSilentAudio()`
- `startVAD()`, `toggleVAD()`, `startPlaybackVAD()`, `stopPlaybackVAD()`, `startThinkingVAD()`, `stopThinkingVAD()`
- `toggleAutoInterrupt()`, `interruptPlayback()`
- `pttStart()`, `pttEnd()`, `_isTextTarget()`
- `updateMicUI()`, `MIC_SVG`, `MIC_SEND_SVG`, `MIC_INTERRUPT_SVG`

#### `player.js`
- `playAudio()`, `enqueueAudio()`, `_playNextQueued()`, `_audioPlayQueue`
- `playBufferedAudio()`, `padAudioBuffer()`, `getAudioPadSec()`
- `playMessageTTS()`, `stopTTSPlayback()`, `stopActiveAudio()`
- `karaokeSetupMessage()`, `_applyKaraokeSpans()`, `karaokeStart()`, `_karaokeFrame()`, `karaokeStop()`, `karaokeSeekTo()`, `karaokePlayFromWord()`, `_pendingKaraokeWords`
- `_wrapWordsInSpans()`, `_wrapTextNodesInKaraokeSpans()`
- `startThinkingSound()`, `stopThinkingSound()`, `toggleThinkingSounds()`
- Transport: `updateTransportBar()`, `transportPause()`, `transportNext()`, `transportPrev()`

#### `audio.js` (remains)
- `audioCtx` — shared AudioContext singleton
- `playTone()`, `cueListening()`, `cueProcessing()`, `cueSessionReady()`, `toggleAudioCues()`
- Waveform: `startWaveform()`, `drawWaveform()`, `stopWaveform()`, `waveCanvas`, `waveCtx`
- Session state: `setSessionState()`, `getSessionState()`, `_handleListeningUI()`, `_checkPendingListen()`
- Status stubs: `showStatusIndicator()`, `hideStatusIndicator()`, etc.

### Shared state access

These are currently module-level variables shared across functions:

- `audioCtx` — the Web Audio context (stays in `audio.js`, imported by others)
- `sessions` Map — from `state.js` (already external)
- `_audioPlayQueue` Map — moves to `player.js`
- `_pendingKaraokeWords` Map — moves to `player.js`
- Recording state vars (`mediaRecorder`, `audioChunks`, etc.) — move to `recorder.js`

**Approach:** Since these are plain `<script>` tags (no ES modules), all top-level variables are global. No import mechanism needed — just ensure load order in `hub.html`:
```html
<script src="/static/js/state.js"></script>
<script src="/static/js/audio.js"></script>     <!-- shared context, cues -->
<script src="/static/js/player.js"></script>    <!-- playback, karaoke -->
<script src="/static/js/recorder.js"></script>  <!-- capture, VAD -->
```

---

## Migration strategy

1. **Extract, don't rewrite.** Move functions verbatim — no refactoring during the split.
2. **One file at a time.** Split `hub.py` first (Python has proper imports), then `audio.js`.
3. **Test after each extraction.** Verify the hub starts, browser loads, and voice pipeline works.
4. **Keep `state_machine.py` separate** as its own module.
