# ClawMux

The Hub is a standalone service that spawns and manages multiple Claude Code voice sessions from a single browser tab.

## Architecture

```
Browser ←—single WSS—→ Hub (:3460) ←—WS—→ MCP Server A (Claude session 1)
                                    ←—WS—→ MCP Server B (Claude session 2)
                                    ←—WS—→ MCP Server C (Claude session 3)
```

### How It Works

1. **Hub** (`hub.py`) runs on port 3460 as a standalone FastAPI service
2. **Browser** connects to the hub via a single WebSocket
3. When you click "New Session", the hub:
    - Creates a temp directory at `/tmp/voice-hub-sessions/{session-id}/`
    - Writes a `.mcp.json` into that directory with the session ID baked in
    - Starts a tmux session and launches `claude --dangerously-skip-permissions` from that directory
    - Claude Code picks up the project-level `.mcp.json` and spawns `hub_mcp_server.py`
    - `hub_mcp_server.py` reads `VOICE_HUB_SESSION_ID` from its MCP env config and connects back to the hub via WebSocket at `ws://127.0.0.1:3460/mcp/{session-id}`
    - Hub sends `/voice-hub` to the tmux session so Claude enters voice mode
4. **Audio flow** for `converse()`:
    - Claude calls `converse("Hello")` → `hub_mcp_server.py` forwards to hub via WS
    - Hub does TTS (Kokoro) using the session's configured voice → sends MP3 to browser tagged with session_id
    - Hub sends `assistant_text` with the spoken text for the chat transcript
    - Browser plays audio → sends `playback_done` tagged with session_id
    - Hub tells browser to record → browser records (or sends silence if mic muted) → sends audio tagged with session_id
    - Hub does STT (Whisper) → sends `user_text` for the chat transcript → sends text back to `hub_mcp_server.py`
    - `hub_mcp_server.py` returns the text to Claude

### Key Insight: Dynamic MCP Config

Claude Code MCP servers get their environment **only from `.mcp.json`**, not from the shell that launched `claude`. So we can't pass a session ID via env vars on the command line. Instead, the hub creates a per-session directory with a `.mcp.json` that has the session ID baked into the `env` field:

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

## Components

| File | Role |
|------|------|
| `hub.py` | FastAPI service — REST API, browser WS, MCP WS, TTS/STT |
| `hub_mcp_server.py` | Thin MCP server — proxies converse() to hub via WS |
| `hub_config.py` | Constants (port, timeout, service URLs) |
| `session_manager.py` | tmux lifecycle, temp dir creation, health checks |
| `static/hub.html` | Browser UI — session tabs, audio, mic, controls |

## Running

```bash
# Start the hub
cd ~/GIT/voice-hub-dev
source .venv/bin/activate
python hub.py

# Expose via Tailscale (one-time)
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Open `https://workstation.tailee9084.ts.net:3460` and click "New Session".

## Browser Controls

| Control | Location | Description |
|---------|----------|-------------|
| Mic button | Center | Tap to start/stop recording. Pulses red when recording. |
| Mic mute | Left of mic | Mutes microphone input. When muted, sessions receive `(session muted)` instead of speech. |
| Auto/Manual toggle | Right of mic | **Auto**: recording starts automatically after Claude speaks. **Manual**: tap mic to respond. |
| Voice selector | Far right | Choose TTS voice per session (Sky, Alloy, Sarah, Adam, Echo, Onyx, Fable). |
| Session tabs | Top bar | Click to switch sessions. Green dot = ready, yellow = starting, blue = active. |
| Badge (!) | On tab | Appears when a background session needs attention. |
| Close (×) | On tab | Terminates the session and its tmux process. |

## Debugging

```bash
# Hub logs
tail -f /tmp/voice-hub.log

# MCP server logs (per-session)
tail -f /tmp/voice-hub-mcp.log

# See spawned tmux sessions
tmux ls

# Attach to a session
tmux attach -t voice-1-abc123

# Check temp directories
ls /tmp/voice-hub-sessions/
```

## Session Lifecycle

| State | Description |
|-------|-------------|
| `starting` | tmux created, Claude booting, MCP server connecting |
| `ready` | MCP connected to hub, Claude in voice mode |
| `active` | `converse()` call in progress |
| `dead` | tmux died or session timed out |

Sessions auto-terminate after 30 minutes of inactivity (configurable via `VOICE_CHAT_TIMEOUT` env var on the hub).

## Slash Commands

| Command | MCP Server | Use Case |
|---------|-----------|----------|
| `/voice-hub` | `voice-hub` | Direct voice chat (main branch, port 3456) |
| `/voice-hub-dev` | `voice-hub-dev` | Direct voice chat (dev branch, port 3457) |
| `/voice-hub` | `voice-hub` | Hub-managed session (used by spawned sessions) |

## REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/sessions` | List all sessions |
| `POST` | `/api/sessions` | Spawn a new session |
| `DELETE` | `/api/sessions/{id}` | Terminate a session |
| `PUT` | `/api/sessions/{id}/voice` | Set session voice (`{"voice": "am_adam"}`) |

## Protocol

### Browser ↔ Hub

All session messages include `session_id`:

```json
{"session_id": "voice-1-abc123", "type": "audio", "data": "base64..."}
{"session_id": "voice-1-abc123", "type": "playback_done"}
```

Hub → Browser session messages:
```json
{"session_id": "...", "type": "audio", "data": "base64..."}
{"session_id": "...", "type": "assistant_text", "text": "Hello!"}
{"session_id": "...", "type": "user_text", "text": "Hi there"}
{"session_id": "...", "type": "listening"}
{"session_id": "...", "type": "status", "text": "Speaking..."}
{"session_id": "...", "type": "done"}
```

Hub-only messages (no session_id):
```json
{"type": "session_list", "sessions": [...]}
{"type": "session_status", "session_id": "...", "status": "ready"}
{"type": "session_terminated", "session_id": "..."}
```

### Hub ↔ MCP Server

Each MCP server connects to `ws://hub:3460/mcp/{session_id}`:

```json
// MCP → Hub
{"type": "converse", "message": "Hello", "wait_for_response": true, "voice": "af_sky"}
{"type": "status_check"}

// Hub → MCP
{"type": "converse_result", "text": "User said something"}
{"type": "status_result", "connected": true}
```

Note: The `voice` field in the converse message from MCP is ignored — the hub uses the session's voice setting from the browser UI instead.
