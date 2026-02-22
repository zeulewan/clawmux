# WebSocket Protocol

Complete message reference for browser and MCP clients connecting to the hub.

## Endpoints

| Endpoint | Who connects | Purpose |
|----------|-------------|---------|
| `ws(s)://{host}:{port}/ws` | Browser (single connection, last-wins) | All browser-hub communication |
| `ws://{host}:{port}/mcp/{session_id}` | `hub_mcp_server.py` (one per session) | Per-session MCP-hub communication |

## Client WebSocket (`/ws`)

Multiple clients can connect simultaneously (browser, iOS app, etc.). All receive the same messages. When the last client disconnects, all sessions with pending `playback_done` waits are unblocked.

### On Connect

Hub sends the full session list:

```json
{"type": "session_list", "sessions": [<session_object>, ...]}
```

### Browser → Hub

All messages must include `session_id`:

| Type | Fields | Description |
|------|--------|-------------|
| `playback_done` | `session_id` | Audio playback finished, hub can proceed to listen phase |
| `audio` | `session_id`, `data` (base64 webm) | Recorded user audio. Empty `data` = muted/cancelled |

```json
{"session_id": "voice-1-abc123", "type": "playback_done"}
{"session_id": "voice-1-abc123", "type": "audio", "data": "base64..."}
```

### Hub → Browser (Session-scoped)

All include `session_id`:

| Type | Fields | Description |
|------|--------|-------------|
| `audio` | `data` (base64 MP3) | TTS audio to play |
| `assistant_text` | `text` | Claude's spoken text for chat display |
| `user_text` | `text` | Transcribed user speech for chat display |
| `listening` | — | Browser should start recording (or queue pending listen) |
| `status` | `text` | Status update (e.g. "Speaking...", "Transcribing...") |
| `done` | — | Converse turn complete, session returns to ready |
| `session_ended` | — | Agent said goodbye, session will terminate |

```json
{"session_id": "voice-1-abc123", "type": "audio", "data": "base64mp3..."}
{"session_id": "voice-1-abc123", "type": "assistant_text", "text": "Hello!"}
{"session_id": "voice-1-abc123", "type": "user_text", "text": "Hi there"}
{"session_id": "voice-1-abc123", "type": "listening"}
{"session_id": "voice-1-abc123", "type": "status", "text": "Speaking..."}
{"session_id": "voice-1-abc123", "type": "done"}
{"session_id": "voice-1-abc123", "type": "session_ended"}
```

### Hub → Browser (Hub-level)

No `session_id`:

| Type | Fields | Description |
|------|--------|-------------|
| `session_list` | `sessions` (array of session objects) | Full session list, sent on connect |
| `session_status` | `session_id`, `status` | Session state changed (e.g. "ready") |
| `project_status` | `session_id`, `project`, `area` | Agent's current project context updated |
| `session_terminated` | `session_id` | Session was terminated |
| `ping` | — | Heartbeat every 30s. Clients should ignore (no response needed). |

```json
{"type": "session_list", "sessions": [{...}, {...}]}
{"type": "session_status", "session_id": "voice-1-abc123", "status": "ready"}
{"type": "project_status", "session_id": "voice-1-abc123", "project": "voice-hub", "area": "frontend"}
{"type": "session_terminated", "session_id": "voice-1-abc123"}
{"type": "ping"}
```

## MCP WebSocket (`/mcp/{session_id}`)

One connection per session. The `hub_mcp_server.py` instance connects here after being spawned by Claude Code.

### MCP Server → Hub

| Type | Fields | Description |
|------|--------|-------------|
| `converse` | `message`, `wait_for_response` (bool), `voice` (ignored) | Speak and optionally listen |
| `set_project_status` | `project`, `area` (optional) | Update sidebar with current project context |
| `status_check` | — | Check if browser is connected |

```json
{"type": "converse", "message": "Hello!", "wait_for_response": true, "voice": "af_sky"}
{"type": "set_project_status", "project": "voice-hub", "area": "frontend"}
{"type": "status_check"}
```

Note: The `voice` field in `converse` is ignored by the hub. The hub uses the session's voice setting from the browser UI.

### Hub → MCP Server

| Type | Fields | Description |
|------|--------|-------------|
| `converse_result` | `text` | User's transcribed speech, or status string |
| `status_result` | `connected` (bool) | Whether browser is connected |

```json
{"type": "converse_result", "text": "User said something"}
{"type": "status_result", "connected": true}
```

#### `converse_result` values

| Value | Meaning |
|-------|---------|
| User's speech | Normal transcribed text |
| `(no speech detected)` | STT returned empty text |
| `Message delivered.` | `wait_for_response` was false, audio played |
| `Error: ...` | Something went wrong |

Note: `(session muted)` is no longer returned. The hub now retries internally when audio is empty or clients disconnect — the converse call blocks until real audio arrives or a client reconnects.

## Session Object

Returned by REST API and included in `session_list`:

```json
{
  "session_id": "voice-1-abc123",
  "tmux_session": "voice-1-abc123",
  "status": "ready",
  "created_at": 1739980000.0,
  "last_activity": 1739980100.0,
  "label": "Sky",
  "voice": "af_sky",
  "speed": 1.0,
  "mcp_connected": true,
  "status_text": ""
}
```

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | string | Unique ID (`voice-{n}-{uuid6}`) |
| `tmux_session` | string | tmux session name (same as session_id) |
| `status` | string | `starting`, `ready`, `active`, or `dead` |
| `created_at` | float | Unix timestamp |
| `last_activity` | float | Unix timestamp of last converse or browser interaction |
| `label` | string | Display name (voice name) |
| `voice` | string | Kokoro voice ID |
| `speed` | float | TTS speed multiplier |
| `mcp_connected` | bool | Whether the MCP server WebSocket is connected |
| `status_text` | string | Current activity: `"Speaking..."`, `"Listening..."`, `"Transcribing..."`, `"Waiting for client..."`, or `""` (idle) |
| `project` | string | Current project/repo name (set by agent via `set_project_status`) |
| `project_area` | string | Current sub-area (e.g. `"frontend"`, `"docs"`) |

## REST API

| Method | Path | Body | Response |
|--------|------|------|----------|
| `GET` | `/api/sessions` | — | `[<session_object>, ...]` |
| `POST` | `/api/sessions` | `{"voice": "am_adam"}` (optional) | `<session_object>` |
| `DELETE` | `/api/sessions/{id}` | — | `{"status": "terminated"}` |
| `PUT` | `/api/sessions/{id}/voice` | `{"voice": "am_adam"}` | `{"voice": "am_adam"}` |
| `PUT` | `/api/sessions/{id}/speed` | `{"speed": 1.5}` | `{"speed": 1.5}` |
| `GET` | `/api/history/{voice_id}` | — | `{"voice_id": "...", "messages": [{role, text, ts}, ...]}` |
| `DELETE` | `/api/history/{voice_id}` | — | `{"status": "cleared", "voice_id": "..."}` |
| `GET` | `/api/settings` | — | `{"model": "opus", "auto_record": false, "auto_end": true, "auto_interrupt": false}` |
| `PUT` | `/api/settings` | `{"model": "haiku"}` (partial update) | Full settings object |
| `GET` | `/api/debug` | — | Hub info, sessions, tmux, services |
| `GET` | `/api/debug/log` | — | `{"lines": [...]}` (last 50 hub log lines) |

## Converse Flow

The full sequence for one `converse()` call:

```
MCP Server                    Hub                         Browser
    |                          |                              |
    |-- converse(msg) -------->|                              |
    |                          |-- assistant_text ----------->|
    |                          |-- status "Speaking..." ----->|
    |                          |-- [TTS via Kokoro] --------->|
    |                          |-- audio (base64 MP3) ------->|
    |                          |                              |-- plays audio
    |                          |<-------- playback_done ------|
    |                          |-- listening ---------------->|
    |                          |                              |-- records audio
    |                          |<-------- audio (base64) -----|
    |                          |-- [STT via Whisper] -------->|
    |                          |-- user_text ---------------->|
    |                          |-- done --------------------->|
    |<-- converse_result ------|                              |
```

If `wait_for_response=false`, the flow ends after audio playback with `done` + `session_ended`.

### Resilience

The hub handles client disconnects gracefully during converse:

- **No clients when sending audio** — `playback_done` is auto-set, flow continues to listen phase
- **Client disconnects during playback** — `playback_done` is set by the disconnect handler
- **Audio arrives during playback wait** — the hub skips the `playback_done` wait and uses the audio immediately (supports device switching mid-flow)
- **No clients during listen phase** — hub waits for a client to reconnect, then re-sends `listening`
- **Empty/muted audio** — hub retries listening instead of returning to Claude
- **`listening` re-sent every 5 seconds** — ensures newly connected clients pick up the pending listen
