# Voice Hub Development

## hub.html is fragile

`static/hub.html` is a single-file application with all JS inline. A syntax error anywhere in the `<script>` block kills the entire page — the WebSocket never connects and the UI shows "Connecting..." with no useful error for the user.

**After editing hub.html, always verify there are no JS syntax errors.** Common mistakes:
- Missing trailing commas in object literals (especially when adding entries to `VOICE_NAMES`, `VOICE_COLORS`, `VOICE_ICONS`)
- Mismatched braces or brackets
- Unterminated template literals

Quick check: open the browser console and look for `SyntaxError` before assuming the hub or network is broken.

## Formatting Rules

- **Always format URLs as clickable markdown links**: `[Link Text](https://url)` — never paste raw URLs in converse output.

## Hub Restart Policy

**Only Manager 1 (Sky) may restart or reload the hub.** No other agent should run `clawmux reload`, `clawmux stop`, or otherwise restart the hub process. If your changes require a hub reload, message Manager 1 and ask them to do it.

## Manager Hierarchy

- **Manager 1 (Primary):** Sky — primary communication with Zeul, coordinates all agents, sole authority to restart the hub
- **Manager 2 (Secondary):** Sarah — can delegate tasks, spin up agents, and communicate with Zeul if Manager 1 is unavailable

**Manager behavior:** Managers should primarily delegate tasks to worker agents rather than doing work directly. Only perform tasks yourself if Zeul explicitly asks you to, or if no workers are available. Your role is coordination — assign work, track progress, and relay results.

**Acknowledging messages:** When Zeul gives you a straightforward task that doesn't need clarification, just ack the message (bare `--re` with no text) and go do it. Don't say "Got it" or "Understood" — a thumbs-up is enough. Only send a verbal response if you need to clarify, the task is complex enough to confirm your plan, or there's something ambiguous in the request.

## ClawMux CLI Reference

The `clawmux` CLI is the primary interface for voice conversation, inter-agent messaging, and hub management. It connects to the ClawMux hub via WebSocket and HTTP APIs.

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `CLAWMUX_SESSION_ID` | Session ID (required for converse/send/ack/reply/project) | — |
| `CLAWMUX_PORT` | Hub port | `3460` |

These are automatically set when an agent session is spawned. Never export them manually.

---

### Hub Management

#### `clawmux start`
Start the ClawMux hub. No-ops if already running.

```bash
clawmux start
```

#### `clawmux stop`
Gracefully stop the hub. Agent tmux sessions are preserved and will auto-reconnect on next `start`/`reload`.

```bash
clawmux stop
```

#### `clawmux reload`
Stop and restart the hub. Active agent sessions reconnect automatically.

```bash
clawmux reload
```

> **Note:** Only Manager 1 (Sky) may run `reload`, `stop`, or `start`. Other agents must request a restart via messaging.

#### `clawmux kill-all`
Full teardown — stops the hub AND kills all `voice-*` tmux sessions.

```bash
clawmux kill-all
```

---

### Status & Info

#### `clawmux status`
Show hub overview: uptime, browser connection status, and all active sessions grouped by project.

```bash
clawmux status
```

#### `clawmux status <agent>`
Show detailed info for a specific agent (by name, voice ID, or session ID).

```bash
clawmux status sky
clawmux status af_nova
```

Output includes: voice, status, session ID, project, area, work directory, and model.

#### `clawmux projects`
List all configured projects with agent counts and active status.

```bash
clawmux projects
```

#### `clawmux messages`
List inter-agent message history.

```bash
clawmux messages                    # All messages
clawmux messages --session <id>     # Filter by session ID
```

Output format: `msg_id  sender → recipient  [state]  content_preview`

---

### Voice Conversation

#### `clawmux converse "<message>"`
Speak a message via TTS and listen for the user's spoken response via STT. The transcribed response is printed to stdout.

```bash
# Speak and wait for response (default)
clawmux converse "What should I work on next?"

# Speak without waiting for response
clawmux converse "Done with that task." --no-listen

# End the session after speaking
clawmux converse "Goodbye!" --goodbye

# Speak with empty message to just listen
clawmux converse ""

# Override TTS voice
clawmux converse "Hello" --voice af_sky
```

**Flags:**

| Flag | Description |
|---|---|
| `--no-listen` | Speak and exit immediately without waiting for user response |
| `--goodbye` | End the session after speaking |
| `--voice <id>` | Override TTS voice (e.g. `af_sky`, `am_echo`, `af_nova`) |

**Behavior:**
- Without `--no-listen`: blocks indefinitely (up to 24h) waiting for user speech
- With `--no-listen`: speaks and returns within ~5 minutes
- Transcribed user speech is printed to stdout
- Empty message (`""`) starts listening silently

---

### Inter-Agent Messaging

#### `clawmux send --to <agent> "<message>"`
Send a message to another agent. The message is injected into their session.

```bash
# Fire and forget
clawmux send --to alloy "FYI, I pushed a fix to main."

# Wait for acknowledgment (30s timeout)
clawmux send --to alloy --wait-ack "Can you check the auth module?"

# Wait for a reply (120s timeout)
clawmux send --to alloy --wait-response "What port is the dev server on?"
```

**Flags:**

| Flag | Description |
|---|---|
| `--to <agent>` | **(required)** Recipient agent name (e.g. `sky`, `alloy`, `echo`) |
| `--wait-ack` | Block until recipient acknowledges (30s timeout) |
| `--wait-response` | Block until recipient replies (120s timeout) |

**Output:** Prints the message ID (e.g. `msg-a1b2c3d4`) to stdout. If `--wait-response`, prints the reply text.

#### `clawmux ack <msg_id>`
Acknowledge receipt of a message. This unblocks a sender who used `--wait-ack`.

```bash
clawmux ack msg-a1b2c3d4
```

#### `clawmux reply <msg_id> "<message>"`
Reply to a specific message. This unblocks a sender who used `--wait-response`.

```bash
clawmux reply msg-a1b2c3d4 "The dev server is on port 3000."
```

---

### Session Management

#### `clawmux spawn`
Launch a new agent session via the hub.

```bash
# Default CLI mode with random voice
clawmux spawn

# Specify voice
clawmux spawn --voice am_echo

# With custom label
clawmux spawn --voice af_sky --label "Sky Agent"
```

**Flags:**

| Flag | Description | Default |
|---|---|---|
| `--voice <id>` | TTS voice (e.g. `af_sky`, `am_echo`, `am_onyx`) | random |
| `--label <name>` | Custom display label for the session | — |

**Output:** Prints session ID and voice.

#### `clawmux project "<name>"`
Set the project and area displayed in the sidebar for your session.

```bash
clawmux project voice-hub
clawmux project voice-hub --area frontend
clawmux project clawmux --area "CLI docs"
```

**Flags:**

| Flag | Description |
|---|---|
| `--area <area>` | Sub-area (e.g. `frontend`, `backend`, `docs`) |

---

### Monitoring

#### `clawmux monitor`
Open a tmux session with a tiled grid of panes, each showing one agent's session. Includes a live watcher that auto-updates when agents join or leave.

```bash
# Monitor all agents in the default project
clawmux monitor

# Monitor a specific project
clawmux monitor hnapp

# Monitor specific agents only
clawmux monitor --agents sky adam echo

# Create monitor without attaching to it
clawmux monitor --detach

# Kill existing monitor and recreate
clawmux monitor --restart

# Static snapshot (no auto-update watcher)
clawmux monitor --no-live
```

**Flags:**

| Flag | Description |
|---|---|
| `project` | (positional, optional) Project slug to monitor. Defaults to `default` |
| `--agents <names...>` | Monitor only these agents by name |
| `--detach` | Create the monitor session without attaching to it |
| `--restart` | Kill existing monitor session and recreate from scratch |
| `--no-live` | Disable the background watcher that auto-adds/removes panes |

**Behavior:**
- Creates tmux session named `clawmux-monitor` (or `clawmux-monitor-<project>`)
- Panes auto-arrange in a grid layout (e.g. 3x3 for 9 agents)
- Each agent gets a color-coded tmux status bar
- Panes auto-reconnect if an agent session restarts
- Live watcher polls every 3s and logs to `/tmp/clawmux-monitor-watcher.log`
