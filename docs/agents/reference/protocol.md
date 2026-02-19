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
| `session_terminated` | `session_id` | Session was terminated |
| `ping` | — | Heartbeat every 30s. Clients should ignore (no response needed). |

```json
{"type": "session_list", "sessions": [{...}, {...}]}
{"type": "session_status", "session_id": "voice-1-abc123", "status": "ready"}
{"type": "session_terminated", "session_id": "voice-1-abc123"}
{"type": "ping"}
```

## MCP WebSocket (`/mcp/{session_id}`)

One connection per session. The `hub_mcp_server.py` instance connects here after being spawned by Claude Code.

### MCP Server → Hub

| Type | Fields | Description |
|------|--------|-------------|
| `converse` | `message`, `wait_for_response` (bool), `voice` (ignored) | Speak and optionally listen |
| `status_check` | — | Check if browser is connected |

```json
{"type": "converse", "message": "Hello!", "wait_for_response": true, "voice": "af_sky"}
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
| `(session muted)` | Mic was muted, empty audio received |
| `(no speech detected)` | STT returned empty text |
| `Message delivered.` | `wait_for_response` was false, audio played |
| `Error: ...` | Something went wrong |

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
  "mcp_connected": true
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
