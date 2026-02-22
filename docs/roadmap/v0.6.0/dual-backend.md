# Dual Backend

Voice Hub supports two agent backends. OpenClaw is the primary path forward; Claude Code via tmux remains as a legacy option.

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

The hub abstracts the session backend behind a common interface. The frontend doesn't know or care which backend is running — it sees the same session list, status updates, and chat messages either way.

## OpenClaw Backend

The hub connects to a local OpenClaw Gateway (`ws://127.0.0.1:18789`) as a WebSocket client. Each voice agent maps to an OpenClaw agent instance.

**Advantages:**

- Full visibility into the agent loop — every tool call, model response, and status change streams through the Gateway
- Native multi-agent support with session isolation
- Inter-agent communication via `sessions_send` / `sessions_spawn`
- Model-agnostic — Claude, GPT, open-source models, or local models on the RTX 3090
- Block streaming for progressive TTS (speak chunks as they arrive)
- No tmux hacking or MCP server bridging

**Setup:** Run OpenClaw Gateway alongside Kokoro and Whisper on the same machine. The hub connects as a Gateway client and creates agent sessions for each voice.

**Default agent:** One primary OpenClaw agent that persists across sessions and knows the user best. Additional named agents spawn on demand with lightweight personality prompts.

## tmux Backend (Legacy)

The current architecture. Hub spawns Claude Code in tmux sessions and communicates via a custom MCP server over WebSocket.

**Advantages:**

- Uses Claude Pro/Max subscription (flat rate, no per-token costs)
- Deep coding capabilities — MCP tools, skills, CLAUDE.md, IDE-level context
- Already working and stable

**Limitations:**

- No visibility into agent loop between converse calls
- Status reporting requires heuristics or tmux polling
- Inter-agent communication requires building a custom message broker
- Sub-agent orchestration requires custom tmux management
- Fragile session management (orphan adoption, reconnection)

## Backend Interface

Both backends implement the same abstract interface:

- `spawn_session(voice, label)` → Session
- `terminate_session(session_id)`
- `send_message(session_id, text)` → response
- `get_status(session_id)` → status
- `list_sessions()` → sessions
- `on_event(callback)` — subscribe to real-time events (status changes, tool calls, messages)

The hub selects the backend based on configuration. A single hub instance runs one backend at a time.

## Migration Path

1. Build the abstract backend interface
2. Refactor current tmux code into the tmux backend
3. Build the OpenClaw backend
4. Make the frontend backend-agnostic
5. Default new installs to OpenClaw, keep tmux as opt-in
