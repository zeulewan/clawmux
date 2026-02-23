# Dual Backend

Voice Hub supports two pluggable agent backends. OpenClaw is the primary path forward; Claude Code via tmux remains as a legacy option.

## Architecture

```
Voice Hub
├── Frontend (browser)
│   └── WebSocket → Hub
├── Hub (Python/FastAPI)
│   ├── TTS (Kokoro)
│   ├── STT (Whisper)
│   └── Session Backend (pluggable)
│       ├── OpenClaw Backend ← primary
│       └── tmux Backend ← legacy
```

The frontend doesn't know which backend is running — same session list, status updates, and chat messages either way.

## OpenClaw Backend

Connects to a local OpenClaw Gateway (`ws://127.0.0.1:18789`). Each voice agent maps to an OpenClaw agent instance.

**Why**: Full visibility into the agent loop, native multi-agent support, model-agnostic, block streaming for progressive TTS, no tmux hacking.

## tmux Backend (Legacy)

Current architecture. Hub spawns Claude Code in tmux sessions via MCP server bridge.

**Why keep it**: Uses Claude Pro/Max subscription (flat rate), deep coding capabilities (MCP tools, skills, CLAUDE.md), already working.

## Backend Interface

Both backends implement: `spawn_session`, `terminate_session`, `send_message`, `get_status`, `list_sessions`, `on_event`. A single hub instance runs one backend at a time, selected by config.

## Migration Path

1. Abstract backend interface
2. Refactor current tmux code into tmux backend
3. Build OpenClaw backend
4. Make frontend backend-agnostic
5. Default new installs to OpenClaw, keep tmux as opt-in
