# For Agents

Reference for AI agents installing, maintaining, or extending Voice Hub. If you're a human, see the [human guide](../humans/index.md).

## Entry Points

Start here depending on what you're working on:

| Role | Document | Description |
|------|----------|-------------|
| **iOS Dev** | [iOS Development](ios-dev.md) | Building the native iOS app. What to read, what to implement, what files to watch |
| **Web Dev** | [Web Development](web-dev.md) | Building browser features. What docs to keep updated, conventions, testing |

## Reference Docs

| Document | Description |
|----------|-------------|
| [Agent Reference](agent-reference.md) | System requirements, installation, file map, core flows, config, debugging |
| [Hub Architecture](hub.md) | How the hub works, components, session lifecycle, slash commands |
| [WebSocket Protocol](protocol.md) | Complete message reference for browser and MCP clients |
| [UI Behavior](ui-behavior.md) | Every state, button, toggle, and audio behavior in the browser UI |
| [Architecture (Legacy)](architecture.md) | Single-session mode architecture (pre-hub) |
| [Configuration](configuration.md) | Environment variables and config options |
| [Getting Started](../guide/getting-started.md) | Quick start guide |

## System Requirements

Before installing, verify the target system meets these requirements.

### GPU

```bash
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
```

- **Required:** NVIDIA GPU with at least 4 GB VRAM
- **Tested on:** RTX 3090 (24 GB)
- CUDA must be available (`nvidia-smi` should work)

### VRAM Budget

| Service | VRAM | RAM | Notes |
|---------|------|-----|-------|
| Whisper STT | ~640 MB | ~360 MB | whisper.cpp with CUDA, `base` model |
| Kokoro TTS | ~2 GB | ~3 GB | kokoro-fastapi with GPU inference |
| **Total** | **~3 GB** | **~3.5 GB** | Plus whatever else is running |

### OS

- Linux required (tested on Ubuntu 24.04)
- Python 3.10+
- tmux installed (`which tmux`)

### Claude Code

```bash
claude --version
```

Must be installed and authenticated. The hub spawns Claude sessions with `claude --dangerously-skip-permissions`.

### Whisper STT

Check if running:

```bash
curl -s http://127.0.0.1:2022/v1/models | head -c 200
```

If not installed, install via [VoiceMode](https://github.com/mbailey/voicemode):

```bash
uvx voice-mode-install --yes
voicemode whisper install
voicemode whisper start
```

Or any OpenAI-compatible STT server on port 2022.

### Kokoro TTS

Check if running:

```bash
curl -s http://127.0.0.1:8880/v1/models | head -c 200
```

If not installed:

```bash
voicemode kokoro install
voicemode kokoro start
```

Or any OpenAI-compatible TTS server on port 8880.

### Tailscale (optional)

```bash
tailscale status
```

Needed for remote access from phones, laptops, or other machines. Not required for localhost use.

## Installation

```bash
git clone https://github.com/zeulewan/voice-chat.git
cd voice-chat
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Dependencies: `fastapi`, `uvicorn`, `httpx`, `python-dotenv`, `python-multipart`, `zensical`, `fastmcp>=2.14`, `websockets`.

### Register MCP Server

For direct voice chat (non-hub, legacy mode):

```bash
claude mcp add -s user voice-chat -- /path/to/voice-chat/.venv/bin/python /path/to/voice-chat/mcp_server.py
```

Hub-spawned sessions register their own MCP server automatically via per-session `.mcp.json` files.

### Install Slash Commands

```bash
mkdir -p ~/.claude/commands
cp .claude/commands/voice-chat.md ~/.claude/commands/voice-chat.md
```

The `/voice-hub` slash command is used internally by hub-spawned sessions. It's injected automatically.

### Tailscale HTTPS (for remote access)

```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Then access at `https://<hostname>.ts.net:3460`.

### Start the Hub

```bash
cd /path/to/voice-chat
source .venv/bin/activate
python hub.py
```

The hub starts on port 3460 by default.

## Architecture

```
Browser  <--single WS-->  Hub (:3460)  <--WS-->  MCP Server A (Claude session 1)
                                        <--WS-->  MCP Server B (Claude session 2)
                                        <--WS-->  MCP Server C (Claude session 3)
```

The hub is a standalone FastAPI service. One browser connects to it over a single WebSocket. Each Claude Code session runs in its own tmux process with a thin MCP server (`hub_mcp_server.py`) that connects back to the hub via a per-session WebSocket.

### Key Design: Dynamic MCP Config

Claude Code MCP servers get their environment **only from `.mcp.json`**, not from the shell that launched `claude`. The hub creates a per-session temp directory with a `.mcp.json` that has the session ID baked into the `env` field:

```json
{
  "mcpServers": {
    "voice-hub": {
      "command": "/path/to/.venv/bin/python",
      "args": ["/path/to/hub_mcp_server.py"],
      "env": {
        "VOICE_HUB_SESSION_ID": "voice-1-abc123",
        "VOICE_CHAT_HUB_PORT": "3460"
      }
    }
  }
}
```

Claude is started from this directory, picks up the project-level config, and the MCP server connects to the hub with the correct session identity.

## File Map

```
voice-chat/
├── hub.py                  # FastAPI service: REST API, browser WS, MCP WS, TTS/STT
├── hub_config.py           # Constants: ports, timeouts, voice list, service URLs
├── hub_mcp_server.py       # Thin MCP server: runs inside each Claude session, proxies converse() to hub
├── session_manager.py      # Session lifecycle: tmux spawn/kill, temp dirs, health checks, timeout loop
├── mcp_server.py           # Legacy single-session MCP server (not used by hub)
├── requirements.txt        # Python dependencies
├── static/
│   ├── hub.html            # Hub browser UI: single file with HTML + CSS + JS (~1200 lines)
│   └── index.html          # Legacy single-session browser UI
├── docs/                   # Zensical docs site (MkDocs-compatible)
└── .claude/
    ├── commands/
    │   └── voice-chat.md   # Slash command for direct voice mode
    └── skills/
        └── voice-chat/
            └── skill.md    # Skill definition for voice chat
```

## Session Lifecycle

### States

| State | Description |
|-------|-------------|
| `starting` | tmux created, Claude booting, MCP server connecting |
| `ready` | MCP connected to hub, Claude in voice mode |
| `active` | `converse()` call in progress |
| `dead` | tmux died or session timed out |

### Spawn Sequence (`session_manager.py:spawn_session`)

1. Increment session counter, generate short UUID
2. Allocate session ID: `voice-{counter}-{uuid6}`
3. Pick next unused voice from `hub_config.VOICES`
4. Create temp dir at `/tmp/voice-hub-sessions/{session_id}/`
5. Write `.mcp.json` with `VOICE_HUB_SESSION_ID` and `VOICE_CHAT_HUB_PORT` env vars
6. Write `CLAUDE.md` with agent name and greeting prompt
7. `tmux new-session -d -s {session_id} -x 200 -y 50 -c {work_dir}`
8. `tmux send-keys` to launch `claude --dangerously-skip-permissions`
9. Wait 10 seconds for Claude to initialize
10. Send `/voice-hub` slash command via tmux send-keys, then Enter
11. Poll for MCP WebSocket connection (45 second timeout)
12. Session status becomes `ready`

### Termination

1. Set session status to `dead`
2. Close the MCP WebSocket connection (code 1001)
3. Kill the tmux session (`tmux kill-session -t {name}`)
4. Remove the temp work directory
5. Remove session from the manager's session map
6. Notify browser via `session_terminated` message

### Timeout

Sessions auto-terminate after 30 minutes of inactivity (configurable via `VOICE_CHAT_TIMEOUT` env var). The health check loop runs every 15 seconds, checking:

- tmux session still alive (`tmux has-session`)
- Time since last activity

### Startup Cleanup

On hub startup, `cleanup_stale_sessions()` runs automatically:

- Finds all tmux sessions matching `voice-*` that aren't tracked by the current hub
- Kills them
- Removes orphaned temp directories from `/tmp/voice-hub-sessions/`

This handles stale sessions left behind by hub crashes or restarts.

## Converse Flow

The core audio loop, implemented in `hub.py:handle_converse`:

1. Claude calls `converse(message, wait_for_response, voice)` on `hub_mcp_server.py`
2. `hub_mcp_server.py` forwards the request to the hub via WebSocket as `{"type": "converse", ...}`
3. Hub sends `assistant_text` to browser (for chat transcript display)
4. Hub sends `status: "Speaking..."` to browser
5. Hub calls Kokoro TTS with the session's voice and speed settings, gets MP3 bytes
6. Hub base64-encodes the MP3 and sends it to browser tagged with `session_id`
7. Hub clears `playback_done` event, waits for browser to finish playing
8. Browser plays audio, sends `{"type": "playback_done", "session_id": "..."}`
9. If `wait_for_response=false`: hub sends `done` and `session_ended`, returns `"Message delivered."`
10. Hub drains any stale audio from the queue
11. Hub sends `listening` to browser
12. Browser starts recording (auto or manual depending on user toggle)
13. Browser sends `{"type": "audio", "session_id": "...", "data": "base64..."}` or empty audio if muted
14. If empty audio: return `"(session muted)"`
15. Hub calls Whisper STT, gets transcribed text
16. Hub sends `user_text` to browser (for chat transcript)
17. Hub sends `done` to browser
18. Hub returns transcribed text to `hub_mcp_server.py` as `{"type": "converse_result", "text": "..."}`
19. `hub_mcp_server.py` returns the text to Claude

## WebSocket Protocol

### Browser WebSocket (`/ws`)

Single connection, last-wins. When a new browser connects, the previous connection is replaced.

On connect, the hub sends:

```json
{"type": "session_list", "sessions": [{...}, {...}]}
```

#### Browser to Hub

All messages include `session_id`:

```json
{"session_id": "voice-1-abc123", "type": "audio", "data": "base64..."}
{"session_id": "voice-1-abc123", "type": "playback_done"}
```

#### Hub to Browser

Session-scoped messages (include `session_id`):

| Type | Fields | Purpose |
|------|--------|---------|
| `audio` | `data` (base64 MP3) | TTS audio to play |
| `assistant_text` | `text` | Claude's response text for chat display |
| `user_text` | `text` | Transcribed user speech for chat display |
| `listening` | | Browser should start recording |
| `status` | `text` | Status message (e.g. "Speaking...", "Transcribing...") |
| `done` | | Converse turn complete |
| `session_ended` | | Session is closing (after goodbye) |

Hub-level messages (no `session_id`):

| Type | Fields | Purpose |
|------|--------|---------|
| `session_list` | `sessions` (array) | Full session list on connect |
| `session_status` | `session_id`, `status` | Session state change |
| `session_terminated` | `session_id` | Session was terminated |

### MCP WebSocket (`/mcp/{session_id}`)

One connection per session. The `hub_mcp_server.py` connects here.

#### MCP Server to Hub

```json
{"type": "converse", "message": "Hello", "wait_for_response": true, "voice": "af_sky"}
{"type": "status_check"}
```

Note: The `voice` field in converse is ignored by the hub. The hub uses the session's voice setting from the browser UI.

#### Hub to MCP Server

```json
{"type": "converse_result", "text": "User said something"}
{"type": "status_result", "connected": true}
```

## REST API

| Method | Path | Body | Response | Purpose |
|--------|------|------|----------|---------|
| `GET` | `/` | | HTML | Serve hub.html |
| `GET` | `/static/{filename}` | | File | Serve static assets |
| `GET` | `/api/sessions` | | `[{session}, ...]` | List all sessions |
| `POST` | `/api/sessions` | `{"voice": "am_adam"}` (optional) | `{session}` | Spawn a new session |
| `DELETE` | `/api/sessions/{id}` | | `{"status": "terminated"}` | Terminate a session |
| `PUT` | `/api/sessions/{id}/voice` | `{"voice": "am_adam"}` | `{"voice": "am_adam"}` | Change TTS voice |
| `PUT` | `/api/sessions/{id}/speed` | `{"speed": 1.5}` | `{"speed": 1.5}` | Change TTS speed |

### Session Object

Returned by `GET /api/sessions` and `POST /api/sessions`:

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

## MCP Tools

The `hub_mcp_server.py` exposes two MCP tools to Claude:

### `converse`

Speak a message to the user and optionally listen for a response.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `message` | string | required | Text to speak via TTS |
| `wait_for_response` | bool | `true` | Whether to listen for user speech after playback |
| `voice` | string | `"af_sky"` | Kokoro voice name (ignored by hub, uses session setting) |

Returns the user's transcribed speech, `"(session muted)"`, `"(no speech detected)"`, or `"Message delivered."` if `wait_for_response=false`.

### `voice_chat_status`

Check if a browser is connected to the hub.

Returns a connection status string.

## Browser State Machine (`static/hub.html`)

The browser UI is a single HTML file (~1200 lines) with embedded CSS and JS.

### Key State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `sessions` | Map | session_id to `{label, status, voice, speed, messages[], audioBuffer[], pausedAudio, pendingListen, el}` |
| `activeSessionId` | string | Currently visible tab |
| `recording` | bool | Whether mic is actively recording |
| `recordingSessionId` | string | Which session the recording belongs to |
| `currentAudio` | object | `{audio, sessionId, url}` for currently playing audio |
| `currentBufferedPlayer` | object | Active buffered playback chain |
| `persistentStream` | MediaStream | Reusable mic stream (acquired once, never stopped) |
| `autoMode` | bool | Auto Record toggle state |
| `vadEnabled` | bool | Auto End (VAD) toggle state |
| `micMuted` | bool | Global mic mute state |
| `autoInterruptEnabled` | bool | Auto Interrupt toggle state (voice-based interrupt) |
| `playbackVadInterval` | interval | VAD interval running during playback for voice interrupt |
| `thinkingSoundCtx` | AudioContext | Web Audio context for thinking sound |

### Mic Button States

Managed by `updateMicUI()`:

| State | Button Text | Color | Action on Click |
|-------|-------------|-------|-----------------|
| Playing | Interrupt | Orange | Stop playback, send `playback_done` |
| Recording | Send | Green | Stop recording, send audio |
| Idle | Record | Blue | Start recording |

A Cancel button appears next to Send during recording. It discards the audio and sends silence to prevent the hub from hanging.

### Persistent Mic Stream

The browser acquires mic permission once via `getMicStream()` and reuses the stream for all recordings. This prevents Firefox from blocking `getUserMedia()` when the tab is unfocused (background tab recording).

### Tab Switching and Background Audio

When switching tabs:

- Audio playing on the old tab is paused and stored in `pausedAudio`
- If the old tab had a pending `listening` state, it's saved as `pendingListen`
- Audio from the new tab resumes or plays from the buffer
- Background sessions buffer audio chunks in `audioBuffer[]`

### Auto Record / Auto End / Auto Interrupt

- **Auto Record**: When enabled, recording starts automatically after the hub sends `listening`. The Record button is still visible for manual control.
- **Auto End (VAD)**: When enabled, recording stops automatically when silence is detected (3 seconds of silence, RMS threshold 10). The Send button is still visible for early send.
- **Auto Interrupt**: When enabled, the mic listens during playback. If sustained speech is detected (RMS > 25 for 300ms), playback is interrupted and recording starts automatically. Uses a higher threshold than Auto End to avoid false triggers from speaker bleed.

### Thinking Indicator

When the user sends audio (Claude is processing), animated pulsing dots appear in the chat as a `msg thinking` element. The indicator is removed when `assistant_text` or `done` is received. The `isThinking` flag on the session object persists across tab switches.

### Thinking Sound

A subtle ambient tone plays while Claude is processing. Generated via Web Audio API (no external files): 440Hz sine wave with gain pulsing between 0 and 0.03 at ~0.8Hz. Starts when audio is sent, stops when Claude responds.

## Config (`hub_config.py`)

| Constant | Default | Env Var | Purpose |
|----------|---------|---------|---------|
| `HUB_PORT` | `3460` | `VOICE_CHAT_HUB_PORT` | Hub listen port |
| `WHISPER_URL` | `http://127.0.0.1:2022` | `VOICE_CHAT_WHISPER_URL` | Whisper STT endpoint |
| `KOKORO_URL` | `http://127.0.0.1:8880` | `VOICE_CHAT_KOKORO_URL` | Kokoro TTS endpoint |
| `SESSION_TIMEOUT_MINUTES` | `30` | `VOICE_CHAT_TIMEOUT` | Idle session auto-terminate |
| `HEALTH_CHECK_INTERVAL_SECONDS` | `15` | | Health check loop interval |
| `CLAUDE_COMMAND` | `claude --dangerously-skip-permissions` | | Command to start Claude |
| `TMUX_SESSION_PREFIX` | `voice` | | Prefix for tmux session names |

### Voice List

Seven voices rotate in order, each session gets the next unused voice:

| Voice ID | Display Name |
|----------|-------------|
| `af_sky` | Sky |
| `af_alloy` | Alloy |
| `af_sarah` | Sarah |
| `am_adam` | Adam |
| `am_echo` | Echo |
| `am_onyx` | Onyx |
| `bm_fable` | Fable |

## Per-Session Bridge State

Each `Session` object (in `session_manager.py`) has asyncio primitives for hub-to-browser synchronization:

| Field | Type | Purpose |
|-------|------|---------|
| `audio_queue` | `asyncio.Queue` | Browser sends recorded audio here |
| `playback_done` | `asyncio.Event` | Set when browser signals playback finished |
| `mcp_ws` | WebSocket | Connection to that session's `hub_mcp_server.py` |

These are initialized by `session.init_bridge()` during spawn.

## Logging

| Log File | Source | Content |
|----------|--------|---------|
| `/tmp/voice-chat-hub.log` | `hub.py` | All hub activity: connections, converse flows, errors |
| `/tmp/voice-hub-mcp.log` | `hub_mcp_server.py` | All MCP server instances (shared log file) |

Both also log to stderr.

## Debugging

```bash
# Hub logs (all sessions)
tail -f /tmp/voice-chat-hub.log

# MCP server logs (all sessions share one log)
tail -f /tmp/voice-hub-mcp.log

# List tmux sessions
tmux ls

# Attach to a session to see Claude's output
tmux attach -t voice-1-abc123

# Check session temp dirs
ls /tmp/voice-hub-sessions/

# Kill a stuck session manually
tmux kill-session -t voice-1-abc123

# Check what Claude sessions are running
ps aux | grep claude

# Check VRAM usage
nvidia-smi

# Test Whisper STT directly
curl -X POST http://127.0.0.1:2022/v1/audio/transcriptions \
  -F "file=@test.webm" -F "model=whisper-1"

# Test Kokoro TTS directly
curl -X POST http://127.0.0.1:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello","voice":"af_sky"}' \
  --output test.mp3

# Check hub REST API
curl http://127.0.0.1:3460/api/sessions | python3 -m json.tool
```

## Common Issues

### Stale tmux sessions after hub crash

The hub cleans these up automatically on startup. If you need to clean manually:

```bash
tmux list-sessions | grep "^voice-" | cut -d: -f1 | xargs -I{} tmux kill-session -t {}
rm -rf /tmp/voice-hub-sessions/
```

### MCP server doesn't connect within 45s

Check the tmux session to see if Claude started:

```bash
tmux attach -t voice-1-abc123
```

Common causes: Claude authentication expired, MCP server path wrong in `.mcp.json`, Python venv not set up.

### Browser shows "Disconnected"

The hub's WebSocket endpoint is `ws://127.0.0.1:3460/ws` (or `wss://` via Tailscale). Only one browser connection is supported (last-wins). Opening in a second tab replaces the first.

### No audio playback

Check that Kokoro TTS is running on port 8880. Check the hub log for TTS errors. The browser needs to be focused or have autoplay permissions.

### Recording doesn't work in background tab

The persistent mic stream should handle this. If it fails, check that the mic permission was granted while the tab was focused (the first recording must happen while focused).

### Session shows "muted" responses

The global mic mute is enabled. Check the Mic/Muted button in the browser UI. When muted, all sessions receive `"(session muted)"` instead of speech.
