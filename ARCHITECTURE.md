# ClawMux Architecture

ClawMux is a multi-agent orchestration platform that spawns, manages, and connects multiple Claude Code instances through a shared hub. It provides voice I/O (TTS/STT), a browser-based chat UI, inter-agent messaging, and project management — all coordinated through a single FastAPI server.

## Directory Structure

```
clawmux/
├── clawmux              # CLI tool (Python script, installed to /usr/local/bin)
├── server/              # Backend — FastAPI hub, session management, voice pipeline
│   ├── hub.py           # Main FastAPI app — WebSocket endpoints, REST API, hook handlers
│   ├── session_manager.py  # Session lifecycle — spawn, terminate, health checks
│   ├── state_machine.py    # AgentState enum (STARTING → IDLE → PROCESSING → DEAD)
│   ├── hub_config.py       # Constants — ports, paths, voice pool, model config
│   ├── voice.py            # TTS (Kokoro) and STT (Whisper) pipeline
│   ├── history_store.py    # Per-agent persistent message history (JSON files)
│   ├── inbox.py            # Per-session inbox file for hook-based message delivery
│   ├── message_broker.py   # Inter-agent message tracking (pending → ack → responded)
│   ├── agents_store.py     # Agent metadata store (data/agents.json)
│   ├── project_manager.py  # Multi-project management (data/projects.json)
│   ├── template_renderer.py # CLAUDE.md template rendering per agent
│   ├── pronunciation.json  # TTS pronunciation overrides
│   ├── backends/           # Pluggable agent runtime backends
│   │   ├── base.py         # AgentBackend ABC
│   │   ├── claude_code.py  # Claude Code via tmux (primary backend)
│   │   ├── openclaw.py     # OpenClaw backend (iOS app)
│   │   └── generic_cli.py  # Generic CLI backend
│   └── templates/          # CLAUDE.md templates and role-specific rules
│       ├── claude_md.template  # Main template with {name}, {role}, {project} vars
│       ├── rules/              # Role-specific instruction files
│       │   ├── manager.md
│       │   └── worker.md
│       └── project-defaults.json
├── static/              # Frontend — browser UI
│   ├── hub.html         # Main SPA (3100+ lines — HTML, CSS, inline JS)
│   ├── index.html       # Landing/login page
│   ├── mux.html         # Lightweight multiplexer view
│   └── js/              # Extracted JS modules
│       ├── state.js     # Global shared state variables
│       ├── ws.js        # WebSocket connection, message routing, reconnect sync
│       ├── audio.js     # Mic recording, TTS playback, karaoke, VAD
│       ├── chat.js      # Message rendering, markdown, threading, text input
│       ├── sidebar.js   # Sidebar rendering, agent status, drag-and-drop
│       └── notes.js     # Notes panel (per-session scratch notes)
├── hooks/               # Claude Code hook scripts
│   └── stop-check-inbox.sh  # Stop hook — checks sentinel + inbox, directs Claude
├── data/                # Runtime data directory (gitignored)
├── docs/                # Additional documentation
├── ios/                 # iOS app source (OpenClaw client)
├── website/             # Documentation website (zensical/mkdocs)
├── install.sh           # Installation script
├── start-hub.sh         # Hub startup wrapper
├── stop-hub.sh          # Hub shutdown wrapper
├── requirements.txt     # Python dependencies
└── .env                 # Environment variables
```

## Backend Architecture

### FastAPI App (`server/hub.py`)

The hub is a single FastAPI application (~1700 lines) running on port 3460 (configurable via `CLAWMUX_PORT`). It handles:

**WebSocket Endpoints:**
- `/ws` — Browser WebSocket. Pushes all UI events (messages, status, audio). Handles incoming voice/text from the browser. On connect, sends `session_list` and flushes any queued messages.
- `/ws/wait/{session_id}` — Agent wait WebSocket. One-shot blocking connection: agent connects, receives one batch of messages, disconnects. Sets agent state to IDLE on connect, PROCESSING on disconnect.

**REST API Endpoints (key ones):**
- `POST /api/hooks/tool-status` — Receives Claude Code hooks (PreToolUse, PostToolUse, Stop, PreCompact, Notification, SessionStart). Updates agent state and delivers inbox messages via `additionalContext`.
- `GET /api/history/{voice_id}` — Message history with optional `?after=<msg_id>` cursor.
- `POST /api/send` — Inter-agent messaging (from CLI `clawmux send`).
- `POST /api/speak` — Agent-to-user speech (from CLI `clawmux send --to user`).
- `POST /api/sessions/{id}/spawn` — Spawn a new agent session.
- `POST /api/sessions/{id}/terminate` — Kill an agent.
- `GET /api/sessions` — List all sessions with state.
- `GET /api/inbox/{session_id}` — Read and clear inbox (used by stop hook).
- `POST /api/tts`, `POST /api/transcribe` — TTS and STT endpoints (in `voice.py` router).

**Hook System:**
Claude Code sends HTTP POST requests to `/api/hooks/tool-status` on every tool use. The hub uses these to:
1. Track agent activity (which tool is running)
2. Deliver queued inbox messages via `additionalContext` in the hook response
3. Manage state transitions (COMPACTING detection, etc.)

### Session Manager (`server/session_manager.py`)

Manages the full lifecycle of agent sessions:
- **Session dataclass** — Holds all per-agent state: `session_id`, `voice`, `state`, `work_dir`, `model`, `interjections`, `claude_session_id`, etc.
- **Spawning** — Creates work directory under `~/.clawmux/sessions/{voice_id}/`, renders CLAUDE.md from template, delegates to backend.
- **Health checks** — Periodic liveness checks via the backend. Detects dead sessions.
- **Orphan adoption** — On startup, discovers existing tmux sessions and re-adopts them.
- **Model switching** — Hot-swap Claude model (opus/sonnet/haiku) with conversation resume.

### State Machine (`server/state_machine.py`)

```
STARTING → IDLE → PROCESSING → IDLE → ...
                ↘ COMPACTING ↗
ANY → DEAD
```

- **STARTING** — Session spawned, Claude Code booting.
- **IDLE** — Agent in `clawmux wait`, ready for messages.
- **PROCESSING** — Agent actively working (making tool calls).
- **COMPACTING** — Claude Code compressing context window.
- **DEAD** — Session terminated.

### Message Delivery

Two mutually exclusive delivery paths, gated by `AgentState`:

1. **IDLE (in wait):** Messages are pushed to `session._wait_queue` → delivered via wait WebSocket immediately.
2. **PROCESSING (working):** Messages are written to the inbox file (`.inbox.jsonl`). PreToolUse/PostToolUse hooks read and clear the inbox, injecting messages via `additionalContext` in the hook response.

The inbox file (`server/inbox.py`) uses `fcntl.flock` for process-safe read/write.

**Stop hook coordination:** When PreToolUse/PostToolUse delivers a message via hooks, the hub writes a `.hook_delivered` sentinel file to the session work directory and sets `session.hook_delivered_message = True`. When Claude finishes a response, the command-type Stop hook (`hooks/stop-check-inbox.sh`) fires:

1. If `.hook_delivered` exists → delete it, tell Claude to process the message it already received via hooks (exit 2, do not call `clawmux wait`)
2. Else if inbox has new messages → deliver them to Claude (exit 2)
3. Else → tell Claude to run `clawmux wait` to enter idle mode (exit 2)

The sentinel file is also cleared when the agent connects to the wait WebSocket, so state resets cleanly each cycle. Note: HTTP hooks cannot block Claude from stopping — only the command-type Stop hook with exit code 2 has this capability.

### Inter-Agent Messaging (`server/message_broker.py`)

Tracks messages through lifecycle states: `pending → acknowledged → responded → failed`. Messages are injected into tmux panes via `tmux send-keys`. The broker handles ack/response routing and retry logic (3 retries, 60s interval, 180s timeout).

### Voice Pipeline (`server/voice.py`)

- **TTS** — Kokoro server at `http://127.0.0.1:8880`. Generates speech with per-agent voices and word-level timestamps for karaoke highlighting.
- **STT** — Whisper server at `http://127.0.0.1:2022`. Supports quality modes: high (large-v3), medium, low (base).
- **Pronunciation** — Custom overrides in `pronunciation.json` for proper nouns and technical terms.

### Agent Backends (`server/backends/`)

Pluggable backend interface (`AgentBackend` ABC) with methods: `spawn`, `terminate`, `health_check`, `deliver_message`, `restart`, `capture_pane`, `apply_status_bar`.

- **ClaudeCodeBackend** — Primary. Runs Claude Code in tmux sessions with `claude --dangerously-skip-permissions`. Configures hooks to POST to the hub.
- **OpenClawBackend** — For iOS OpenClaw app connections.
- **GenericCLIBackend** — For arbitrary CLI agents.

### Configuration

- **`~/.clawmux/data/agents.json`** — Agent metadata (project assignments, roles, areas). Managed by `AgentsStore`.
- **`~/.clawmux/data/projects.json`** — Project definitions and voice assignments. Managed by `ProjectManager`.
- **`~/.clawmux/data/settings.json`** — User preferences (auto_record, tts_enabled, stt_enabled, etc.).
- **`server/hub_config.py`** — Constants: ports, paths, voice pool (27 voices across 3 projects), model defaults.
- **`.env`** — Environment variables (`CLAWMUX_PORT`, `CLAWMUX_HOME`, etc.).

## Frontend Architecture

### Overview

The browser UI is a vanilla JS/HTML/CSS single-page application. No frameworks — all DOM manipulation is direct. The main file is `static/hub.html` (3100+ lines containing HTML structure, all CSS, and ~1400 lines of inline JS). Extracted JS modules live in `static/js/`.

### Script Load Order

```
state.js → ws.js → (inline DOM refs) → audio.js → sidebar.js → chat.js → notes.js → (inline main script)
```

All modules share global (window-scoped) variables. Dependencies are documented in comment headers.

### JS Modules

- **`state.js`** — Global shared variables: `sessions` Map, `activeSessionId`, `ws`, recording state, audio state, UI toggles.
- **`ws.js`** — WebSocket connection (`connect()`), message routing (`handleMessage()`), cursor-based reconnect sync. Handles all incoming WS message types (session_list, session_status, assistant_text, user_text, audio, listening, etc.).
- **`audio.js`** — Mic recording (MediaRecorder API), TTS playback (Web Audio API with buffered streaming), karaoke word highlighting, VAD (voice activity detection), transport controls (pause/resume/scrub), waveform visualization.
- **`chat.js`** — `addMessage()` with ID-based dedup, `renderChat()` with lazy loading and virtual scrolling, markdown rendering (marked.js + DOMPurify + highlight.js), KaTeX math, threading/ack UI, text input mode, drag-and-drop file upload, context menus. **Thinking bubble (`showTypingIndicator`)**: shows animated dots + current tool activity text when agent is processing. Tool call history is accumulated in `_activityLogStore` for ALL sessions (including background tabs), so switching to a busy agent immediately shows the full tool history since its last message — not just blank dots.
- **`sidebar.js`** — Agent cards with state indicators (idle/working/speaking), unread badges, drag-to-reorder, voice grid view, settings panel rendering.
- **`notes.js`** — Per-session scratch notes panel with auto-save.

### HTML Structure (`hub.html`)

```
body
├── #header (logo, active voice name, project selector, model selector)
├── #app-body
│   ├── #sidebar (agent list, settings button)
│   ├── #main-content
│   │   ├── #voice-grid (multi-agent overview)
│   │   ├── #welcome-view
│   │   ├── #focus-view
│   │   ├── #chat-area (message list, append-only)
│   │   ├── #controls (mic, waveform, transport)
│   │   ├── #text-input-bar (typing mode)
│   │   └── #settings-page
│   └── #notes-panel (collapsible side panel)
```

### Data Flow: User Message → Agent → Response

1. User speaks or types in browser
2. Browser sends audio/text via WebSocket to hub
3. Hub transcribes audio (STT) if needed
4. Hub writes message to agent's inbox file + pushes to `_wait_queue` if IDLE
5. Agent receives message via `clawmux wait` (or hook `additionalContext`)
6. Agent processes and calls `clawmux send --to user 'response'`
7. Hub receives via `POST /api/speak`, generates TTS audio
8. Hub pushes `assistant_text` + `audio` events to browser via WebSocket
9. Browser appends message to chat and plays audio with karaoke highlighting

### DOM Update Patterns

- **Append-only for new messages** — `addMessage()` appends a single DOM element. No periodic re-renders.
- **Full render on tab switch** — `renderChat()` clears and rebuilds when switching between agent tabs.
- **Cursor-based reconnect** — On WebSocket reconnect, fetches only messages after the last known ID.
- **Lazy loading** — Shows last 50 messages, loads more on scroll-to-top, unloads on scroll-to-bottom.

## CLI (`clawmux`)

The CLI is a standalone Python script (~1600 lines) installed to `/usr/local/bin/clawmux`. It communicates with the hub via HTTP REST and WebSocket. Each command connects, does one thing, and exits.

### Environment Variables

- `CLAWMUX_SESSION_ID` — Session ID (set automatically in agent tmux sessions)
- `CLAWMUX_PORT` — Hub port (default 3460)

### Key Commands

| Command | Description |
|---------|-------------|
| `clawmux send --to <name> 'msg'` | Send a message to a user or agent |
| `clawmux wait` | Block until a message arrives (one-shot WebSocket) |
| `clawmux status` | Show hub state and all sessions |
| `clawmux spawn <voice_id>` | Launch a new agent session |
| `clawmux start` | Start the hub server |
| `clawmux stop` | Stop the hub gracefully |
| `clawmux reload` | Gracefully restart the hub |
| `clawmux monitor` | Live dashboard of all agent activity |
| `clawmux project <name>` | Set agent's current project/area |
| `clawmux messages` | View message history for a session |
| `clawmux update` | Pull latest code and restart |
| `clawmux version` | Show version info |
| `clawmux kill-all` | Terminate all agent sessions |
| `clawmux regenerate` | Re-render all CLAUDE.md files |
| `clawmux migrate` | Run data migrations |

### How `clawmux wait` Works

1. CLI opens WebSocket to `/ws/wait/{session_id}`
2. Hub sets agent state to IDLE, checks inbox for pending messages
3. If messages pending: sends immediately, returns
4. If empty: blocks on `asyncio.Queue`, polls inbox every 5s as fallback
5. On message received: sends to CLI, CLI prints and exits
6. Hub sets state back to PROCESSING on disconnect

### How `clawmux send` Works

1. CLI POSTs to `/api/send` (inter-agent) or `/api/speak` (to user)
2. Hub resolves recipient session, writes to inbox + pushes to wait queue if IDLE
3. For user messages: generates TTS, pushes audio to browser
4. Returns message ID for threading/acks

## iOS App Architecture (`ios/ClawMux/`)

The iOS app is a native SwiftUI client that connects to the same hub WebSocket as the browser.

### File Structure

| File | Purpose |
|------|---------|
| `ClawMuxApp.swift` | App entry point, `@main` |
| `ContentView.swift` | Root view — body, ZStack layout, `@State` vars, split routing |
| `SidebarView.swift` | Collapsible sidebar (48px collapsed / 220px expanded), agent cards, folder grouping, group chat icons, tray |
| `ChatView.swift` | Chat scroll area, message grouping, `chatBubble`, thinking bubble, scroll-to-bottom |
| `GroupChatView.swift` | Group chat header, scroll, message bubbles |
| `InputBarView.swift` | Bottom input area routing (voice / text / PTT modes) |
| `WelcomeView.swift` | Empty state shown when no session is active |
| `SettingsView.swift` | Settings sheet + sub-screens (AutoMode, PTT, TypingMode) |
| `NotesPanelView.swift` | Notes sheet with auto-save |
| `MarkdownContentView.swift` | Markdown renderer (AttributedString), `ScrollTopDetector`, `ScrollBottomDetector` |
| `Theme.swift` | Adaptive dark/light `Color` extensions, `UIColor(hex:)` helper |
| `ViewHelpers.swift` | `voiceColor()`, `voiceIcon()`, `shortTime()`, `cardStatus()`, `ringColor()` |
| `ShapeHelpers.swift` | `TopOpenRect` (open-top glass shape), `SheetBackgroundModifier` |
| `TonePlayer.swift` | Audio cue tones (start/stop/send sounds) |
| `VADProcessor.swift` | Voice Activity Detection (recording VAD + playback VAD) |
| `ClawMuxViewModel.swift` | All app state (`@Published`), WebSocket, session management, audio recording/playback, hub protocol |

### Key Types

**`ClawMuxViewModel`** (`@StateObject` owned by ContentView) — central state and logic:
- `sessions: [VoiceSession]` — all connected agent sessions
- `activeSession: VoiceSession?` — currently displayed session
- `activeMessages: [ChatMessage]` — messages for active session
- `groupMessages: [GroupChatMessage]` — group chat messages
- `folders: [ProjectFolder]` — live folder list from `/api/projects`
- `isRecording`, `isPlaying`, `audioLevels` — audio state
- `isFocusMode`, `typingMode`, `pushToTalk` — UI mode flags

**`VoiceSession`** — per-agent session state:
- `id`, `voice`, `label`, `state: AgentState` — identity and state
- `project`, `projectArea`, `projectRepo`, `role`, `task` — sidebar metadata
- `isThinking`, `isSpeaking`, `unreadCount` — live status

**`ChatMessage`** — single message:
- `role` — `"user"` | `"assistant"` | `"system"` | `"agent"` | `"activity"`
- `msgId`, `parentId` — for threading and bare-ack reactions
- `isBareAck` — thumbs-up reaction (not displayed, renders 👍 chip on parent)

**`MessageGroup`** — consecutive messages from same role, stable ID for SwiftUI animations:
- `id = role + firstMsgId` (stable across re-renders to prevent animation cascades)

### Connection Model

1. App connects to `ws://{serverURL}/ws` (same endpoint as browser)
2. Hub sends `session_list` → app populates `sessions`
3. Hub sends `project_status` WS events → updates `VoiceSession` metadata live
4. App fetches `/api/sessions` on reconnect for full state sync
5. App fetches `/api/projects` for folder list; updates via `project_created/deleted/renamed` WS events
6. Audio: STT posted to `/api/transcribe`, TTS audio received as `audio` WS events (PCM chunks)

### Critical Layout Rules (DO NOT BREAK)

- `sidebarStripView` MUST end with `.frame(width: sidebarExpanded ? 220 : 48)` — without this, UIKit gives the sidebar full screen width, consuming all touches
- NO `.frame(maxWidth: .infinity)` inside the sidebar's `ScrollView` content `VStack`
- NO `.ignoresSafeArea(edges: .bottom)` on the outer `ZStack`
- NO `safeAreaInset(edge: .top)` on the header/topBar
- `MessageGroup.id` must be stable (role + firstMsgId hash) — UUID() in a computed property causes animation cascades on every state change

### Glass Effect Pattern (iOS 26)

```swift
// Inline glass (blurs content behind):
Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))

// Open-top glass (no rim visible at top/sides — header bars):
Color.clear.glassEffect(.regular, in: TopOpenRect()).ignoresSafeArea(edges: .top)

// Sheet glass (system liquid glass tray):
.presentationBackground(.regularMaterial)
```

`glassEffect` blurs what is spatially behind the view in the same render pass. For the sidebar glass to show actual frosted chat content, the chat `ScrollView` must extend behind the sidebar (use `.contentMargins(.leading, 48)` on scroll content, not `.padding(.leading, 48)` on the scroll view itself).

### Build Workflow

```bash
# On workstation — edit Swift files, then:
git push origin main

# On zmac (100.117.222.41):
ssh zeul@100.117.222.41 'cd /Users/zeul/GIT/clawmux && git pull && ~/.clawmux/build_deploy.sh'
# Installs to device: 9C243483-C00D-5BED-AAD3-25FE73837C8F

# Simulator build:
xcodebuild -project ios/ClawMux.xcodeproj -scheme ClawMux \
  -destination "platform=iOS Simulator,id=DC25B80F-4C70-4009-AF8C-5F35A50D6638" \
  -derivedDataPath /tmp/ClawMux_sim_build build
xcrun simctl install DC25B80F-4C70-4009-AF8C-5F35A50D6638 \
  /tmp/ClawMux_sim_build/Build/Products/Debug-iphonesimulator/ClawMux.app
xcrun simctl launch DC25B80F-4C70-4009-AF8C-5F35A50D6638 com.zeul.clawmux

# xcodeproj regeneration (after adding/removing Swift files):
cd ios && /opt/homebrew/bin/xcodegen generate
```

### Device Trust (iOS 26)

After every phone restart, iOS must re-verify the developer certificate via `ppq.apple.com`. **Tailscale VPN blocks this.** Fix: turn Tailscale off → tap app → enter passcode → Tailscale back on. Device UUID for `devicectl`: `9C243483-C00D-5BED-AAD3-25FE73837C8F`.
