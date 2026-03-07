# For Agents

Reference for AI agents installing, maintaining, or extending ClawMux. If you're a human, see the [human guide](../../humans/index.md).

## System Requirements & Compatibility Check

Before installing, verify the target system meets these requirements. Run these checks:

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

### Tailscale (optional, for remote access)

```bash
tailscale status
```

Needed if the user wants to access from a phone, laptop, or another machine. Not required for localhost use.

### Whisper STT

Check if running:
```bash
curl -s http://127.0.0.1:2022/v1/models | head -c 200
```

If not installed, install via ClawMux services (from the repo root):
```bash
bash services/whisper/install.sh
bash services/whisper/start.sh
```

Or any OpenAI-compatible STT server on port 2022.

### Kokoro TTS

Check if running:
```bash
curl -s http://127.0.0.1:8880/v1/models | head -c 200
```

If not installed (from the repo root):
```bash
bash services/kokoro/install.sh
bash services/kokoro/start.sh
```

Or any OpenAI-compatible TTS server on port 8880.

## Installation

```bash
git clone https://github.com/zeulewan/clawmux.git
cd clawmux
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### Register MCP Server

```bash
claude mcp add -s user clawmux -- /path/to/clawmux/.venv/bin/python /path/to/clawmux/mcp_server.py
```

### Install Slash Commands

```bash
cp .claude/commands/clawmux.md ~/.claude/commands/clawmux.md
mkdir -p ~/.claude/commands
cp .claude/commands/clawmux.md ~/.claude/commands/clawmux.md  # for hub mode
```

### Tailscale HTTPS (for remote access)

```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Then access at `https://<hostname>.ts.net:3460`.

### Start the Hub

```bash
cd /path/to/clawmux
source .venv/bin/activate
python hub.py
```

## File Map

```
clawmux/
├── hub.py                  # Main service — FastAPI, REST API, browser WS, MCP WS, TTS/STT
├── hub_config.py           # Constants — ports, timeouts, voice list, service URLs
├── hub_mcp_server.py       # Thin MCP server — runs inside each Claude session, proxies converse() to hub
├── session_manager.py      # Session lifecycle — tmux spawn/kill, temp dirs, health checks, timeout loop
├── history_store.py        # Per-voice persistent message history (JSON files in data/history/)
├── mcp_server.py           # Legacy single-session MCP server (not used by hub)
├── static/
│   ├── hub.html            # Hub browser UI — single file (HTML + CSS + JS)
│   └── index.html          # Legacy single-session browser UI
├── data/
│   └── history/            # Per-voice JSON history files (gitignored)
│       ├── af_sky.json
│       └── ...
├── docs/
│   ├── agents/
│   │   ├── index.md        # Agent docs landing page
│   │   ├── web-dev.md      # Web development entry point
│   │   ├── ios-dev.md      # iOS development entry point
│   │   └── reference/
│   │       ├── agent-reference.md  # This file
│   │       ├── protocol.md        # WebSocket protocol reference
│   │       ├── ui-behavior.md     # UI behavior reference
│   │       ├── hub.md             # Hub architecture
│   │       └── orchestration.md   # Sub-agent orchestration details
│   ├── humans/
│   │   └── index.md        # Human-friendly guide
│   └── roadmap/
│       ├── v0.3.0.md       # Current release
│       └── v0.4.0.md       # Next release
└── .claude/
    ├── commands/
    │   └── clawmux.md   # Slash command for direct voice mode
    └── skills/clawmux/skill.md
```

## Core Flow

### Session Spawn (`session_manager.py:spawn_session`)

1. Allocate unique session ID: `voice-{counter}-{uuid6}`
2. Pick next unused voice from `hub_config.VOICES`
3. Create temp dir at `/tmp/clawmux-sessions/{session_id}/`
4. Write `.mcp.json` with `CLAWMUX_SESSION_ID` and `CLAWMUX_PORT` env vars
5. Write `CLAUDE.md` with agent name, greeting, and conversation history from `history_store`
6. `tmux new-session` starting in the temp dir
7. `tmux send-keys` to launch `claude --dangerously-skip-permissions`
8. Wait 10s, then send `/clawmux` slash command
9. Poll for MCP WebSocket connection (45s timeout)
10. Session status → `ready`

### Converse Flow (`hub.py:handle_converse`)

1. Receive `{"type": "converse", "message": "...", "wait_for_response": true}` from MCP WS
2. Send `assistant_text` to browser (for chat transcript) and persist to `history_store`
3. TTS via Kokoro (`hub.py:tts`) using session's voice and speed
4. Send base64 MP3 to browser tagged with `session_id`
5. Wait for `playback_done` from browser (via `session.playback_done` asyncio.Event)
6. If `wait_for_response=false`: send `session_ended`, return
7. Send `listening` to browser
8. Wait for audio from browser (via `session.audio_queue`)
9. If empty audio (muted): return `"(session muted)"`
10. STT via Whisper (`hub.py:stt`)
11. Send `user_text` to browser, return text to MCP server

### Browser State Machine (`static/hub.html`)

Key JS state variables:

- `sessions` (Map) — session_id → `{label, status, voice, speed, messages[], audioBuffer[], pausedAudio, pendingListen, hasUnread}`
- `activeSessionId` — currently visible session (null = voice grid)
- `recording` / `recordingSessionId` — mic state
- `currentAudio` — `{audio, sessionId, url}` for playing audio
- `currentBufferedPlayer` — active buffered playback chain
- `persistentStream` — reusable MediaStream (acquired once)
- `autoMode` / `vadEnabled` / `micMuted` — toggle states

Main button states managed by `updateMicUI()`:

- **Playing** → "Interrupt" (orange)
- **Recording** → "Send" (green) + Cancel visible
- **Idle** → "Record" (blue)

## WebSocket Endpoints

| Endpoint | Who connects | Purpose |
|----------|-------------|---------|
| `GET /ws` | Browser (single connection) | All browser ↔ hub communication |
| `GET /mcp/{session_id}` | hub_mcp_server.py instances | Per-session MCP ↔ hub communication |

## REST Endpoints

| Method | Path | Body | Purpose |
|--------|------|------|---------|
| `GET` | `/api/sessions` | — | List all sessions |
| `POST` | `/api/sessions` | `{"voice": "am_adam"}` | Spawn session (voice optional) |
| `DELETE` | `/api/sessions/{id}` | — | Terminate session |
| `PUT` | `/api/sessions/{id}/voice` | `{"voice": "am_adam"}` | Change voice |
| `PUT` | `/api/sessions/{id}/speed` | `{"speed": 1.5}` | Change TTS speed |
| `GET` | `/api/history/{voice_id}` | — | Get per-voice message history |
| `DELETE` | `/api/history/{voice_id}` | — | Clear per-voice message history |

## Per-Session Bridge State (`session_manager.py:Session`)

Each session has asyncio primitives for hub ↔ browser synchronization:

- `audio_queue` (asyncio.Queue) — browser sends recorded audio here
- `playback_done` (asyncio.Event) — set when browser signals playback finished
- `mcp_ws` — WebSocket connection to hub_mcp_server.py

## Config (`hub_config.py`)

| Constant | Default | Env var | Purpose |
|----------|---------|---------|---------|
| `HUB_PORT` | 3460 | `CLAWMUX_PORT` | Hub listen port |
| `WHISPER_URL` | `http://127.0.0.1:2022` | `VOICE_CHAT_WHISPER_URL` | Whisper STT endpoint |
| `KOKORO_URL` | `http://127.0.0.1:8880` | `VOICE_CHAT_KOKORO_URL` | Kokoro TTS endpoint |
| `SESSION_TIMEOUT_MINUTES` | 30 | `VOICE_CHAT_TIMEOUT` | Idle session timeout |
| `VOICES` | 7 entries | — | Voice rotation list |

## Debugging

```bash
# Hub logs (all sessions)
tail -f /tmp/clawmux.log

# MCP server logs (all sessions share one log)
tail -f /tmp/clawmux-mcp.log

# List tmux sessions
tmux ls

# Attach to a session to see Claude's output
tmux attach -t voice-1-abc123

# Check session temp dirs
ls /tmp/clawmux-sessions/

# Kill a stuck session manually
tmux kill-session -t voice-1-abc123
```
