# Server Module

The `server/` directory contains the ClawMux backend — a FastAPI application that orchestrates agent sessions, handles voice I/O, and multiplexes communication between agents and the browser.

## Key Files

### `hub.py` (~1700 lines)
The main FastAPI application. Structured in sections:

- **WebSocket endpoints** — `/ws` (browser), `/ws/wait/{session_id}` (agent wait)
- **Hook handler** — `POST /api/hooks/tool-status` receives Claude Code PreToolUse/PostToolUse/Stop/PreCompact hooks. Updates agent state and delivers inbox messages via `additionalContext`.
- **REST API** — Session CRUD, history, inbox, messaging, TTS/STT, settings, projects
- **Browser message handler** — Routes audio, text, interjections, acks from the browser to the correct agent session
- **Helper functions** — `send_to_browser()` with queue-on-failure, `_inbox_write_and_notify()`, `_format_inbox_messages()`

### `session_manager.py` (~500 lines)
Session lifecycle management:

- **`Session` dataclass** — All per-agent state (voice, model, state, work_dir, interjections, claude_session_id, etc.)
- **`SessionManager`** — Spawn/terminate sessions, health checks, orphan adoption, model hot-swap
- Delegates process operations to pluggable backends

### `state_machine.py`
`AgentState` enum: `STARTING`, `IDLE`, `PROCESSING`, `COMPACTING`, `DEAD`. The wait WebSocket is the sole authority for IDLE/PROCESSING transitions.

### `hub_config.py`
Constants: `HUB_PORT`, `SESSIONS_DIR`, `CLAWMUX_HOME`, voice pool (27 voices), model defaults, TTS/STT URLs, tmux prefix, health check interval.

### `voice.py` (~350 lines)
TTS (Kokoro) and STT (Whisper) pipeline as a FastAPI APIRouter:
- `POST /api/tts` — Text-to-speech with word timestamps for karaoke
- `POST /api/tts-captioned` — TTS with word-level timing data
- `POST /api/transcribe` — Speech-to-text via Whisper
- Text cleanup: strips markdown, code blocks, URLs before TTS
- Pronunciation overrides from `pronunciation.json`

### `history_store.py`
Per-agent message history persisted as JSON files at `~/.clawmux/sessions/{voice_id}/history.json`. Append with file locking (`fcntl.flock`), max 2000 messages. Supports cursor-based queries via the API's `?after=<msg_id>` parameter.

### `inbox.py`
Per-session inbox file (`.inbox.jsonl`) for hook-based message delivery. Uses `fcntl.flock` for process-safe access. Three operations:
- `write()` — Append a message (with auto-generated ID and timestamp)
- `read_and_clear()` — Atomically read all messages and truncate the file
- `peek()` / `peek_latest()` — Non-destructive count/read

### `message_broker.py`
In-memory inter-agent message tracker. States: `pending → acknowledged → responded → failed`. Injects messages into tmux panes via `tmux send-keys`. Retry logic: 3 attempts, 60s interval, 180s ack timeout.

### `agents_store.py`
Manages `~/.clawmux/data/agents.json` — agent metadata (project, role, area). Thread-safe via `asyncio.Lock` with atomic file writes. `AgentEntry` dataclass holds per-agent config.

### `project_manager.py`
Manages `~/.clawmux/data/projects.json` — project CRUD, active project switching, voice-to-project assignment. Supports up to 3 projects of 9 agents each (27 total voices).

### `template_renderer.py`
Renders per-agent CLAUDE.md files from `templates/claude_md.template` with variables: `{name}`, `{role}`, `{project}`, `{area}`, `{managers_section}`, `{role_specific_rules}`. Role rules loaded from `templates/rules/`.

## Subdirectories

### `backends/`
Pluggable agent runtime backends implementing the `AgentBackend` ABC:
- **`base.py`** — Abstract interface: `spawn()`, `terminate()`, `health_check()`, `deliver_message()`, `restart()`, `capture_pane()`, `apply_status_bar()`
- **`claude_code.py`** — Primary backend. Runs `claude --dangerously-skip-permissions` in tmux with hooks configured to POST to the hub.
- **`openclaw.py`** — OpenClaw iOS app backend
- **`generic_cli.py`** — Generic CLI agent backend

### `templates/`
- `claude_md.template` — Main CLAUDE.md template with agent communication protocol, formatting rules, and hub management instructions
- `rules/manager.md` — Manager-specific rules (coordinate agents, speak to user)
- `rules/worker.md` — Worker-specific rules (route through manager)
- `project-defaults.json` — Default agent assignments per project

## Patterns

- **asyncio throughout** — All I/O is async. File operations use `asyncio.to_thread()` to avoid blocking the event loop.
- **Single-threaded event loop** — No threading for state management. The asyncio loop serializes all state mutations.
- **File locking for persistence** — `fcntl.flock` protects history.json and inbox files from concurrent access.
- **State machine guards** — Hook handlers check `session.state` before processing. IDLE state short-circuits most hook logic (wait WS is the authority).
- **Browser message queue** — `_browser_msg_queue` (deque, max 500) buffers messages when no browser is connected, replayed on reconnect.
