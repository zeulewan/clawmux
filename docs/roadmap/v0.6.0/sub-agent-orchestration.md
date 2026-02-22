# Sub-Agent Orchestration

## Overview

Each of the 7 main agents (Sky, Alloy, Sarah, Adam, Echo, Onyx, Fable) acts as a **leader** that can spawn, manage, and communicate with **sub-agents**. Leaders are named voices with their own identity and chat tab. Sub-agents are lightweight workers that inherit their leader's voice and appear nested under the leader in the UI.

The user primarily talks to leaders. Leaders delegate work to sub-agents, monitor their progress, and report results back to the user. The user can also open a sub-agent's chat to inspect its work or send it direct instructions.

## Hierarchy

```
Hub
├── Sky (leader)
│   ├── Sky-A (sub-agent, working on "refactor auth module")
│   ├── Sky-B (sub-agent, working on "write unit tests")
│   └── Sky-C (sub-agent, idle)
├── Alloy (leader)
│   └── Alloy-A (sub-agent, working on "update docs")
├── Adam (leader, no sub-agents)
└── ... other leaders
```

**Naming convention:**

- Leaders: voice display name (Sky, Alloy, Adam, etc.)
- Sub-agents: `{Leader}-{letter}` (Sky-A, Sky-B, Alloy-A, etc.)
- tmux sessions: `voice-sky-a`, `voice-sky-b`, etc.
- Sub-agents use the same TTS voice and speed as their leader

## New MCP Tools for Leaders

### `spawn_worker(task_description)`

Leader spawns a sub-agent. The hub creates a new tmux session, starts Claude Code with `--dangerously-skip-permissions`, and writes a `CLAUDE.md` that includes:

- Sub-agent identity (e.g., "You are Sky-A, a worker for Sky")
- The task description from the leader
- Instructions to use `report_status` and `send_message` to communicate progress back to the leader
- Returns the sub-agent's name (e.g., "Sky-A") for future reference

### `list_workers`

Returns the leader's active sub-agents with names, status, and current task descriptions.

### `kill_worker(name)`

Forcefully terminate a sub-agent. Kills the tmux session immediately. Hub notifies the browser to remove the sub-agent tab.

### `message_worker(name, message)`

Send a text message to a specific sub-agent. Delivered via the sub-agent's inbox (same mechanism as inter-agent messaging).

### `broadcast_workers(message)`

Send a message to all of the leader's active sub-agents at once.

## Sub-Agent Capabilities

Sub-agents get the same MCP tools as leaders:

- `converse` — But typically used with `wait_for_response=false` (report-only mode) since sub-agents usually don't need voice input
- `report_status` — Tell the hub what they're working on
- `send_message` — Message their leader or other agents
- `check_inbox` — Poll for messages from the leader or user

Sub-agents do **not** get:

- `spawn_worker` — No nested sub-agents (single level only)
- `kill_worker`, `list_workers`, `broadcast_workers` — Leader-only tools

## Spawn Flow

1. Leader calls `spawn_worker("Refactor the auth module to use JWT")`
2. Hub creates work dir at `/tmp/voice-hub-sessions/af_sky/workers/sky-a/`
3. Hub writes `.mcp.json` with a new `VOICE_HUB_SESSION_ID`
4. Hub writes `CLAUDE.md` with worker identity and task
5. Hub starts tmux session `voice-sky-a` and launches Claude Code
6. Claude loads the MCP server, connects to hub
7. Hub sends `worker_spawned` to browser → new sub-tab appears under Sky
8. Sub-agent reads its task from `CLAUDE.md` and begins work
9. Sub-agent uses `report_status("Reading auth module...")` to update the UI
10. Sub-agent uses `send_message("Sky", "Done. JWT auth implemented in auth.py")` when finished
11. Leader receives the message via `check_inbox` or next `converse` cycle

## Termination

- **Graceful**: Leader sends `message_worker("Sky-A", "wrap up and shut down")`. Sub-agent finishes current task, sends final status, then exits.
- **Forceful**: Leader calls `kill_worker("Sky-A")`. Hub kills tmux session immediately.
- **Auto-cleanup**: Sub-agents that have been idle for 30 minutes are terminated automatically.
- **Leader termination**: When a leader is terminated, all its sub-agents are killed too.

## Browser UI

### Sub-agent tabs

Sub-agents appear as nested items under their leader in the sidebar/voice grid:

```
┌──────────────────┐
│ ● Sky             │  ← leader (click to chat)
│   ├ Sky-A  ⚙️     │  ← sub-agent (working)
│   ├ Sky-B  ✓      │  ← sub-agent (idle/done)
│   └ Sky-C  ⚙️     │  ← sub-agent (working)
│ ● Alloy           │
│   └ Alloy-A ⚙️    │
│ ○ Adam             │  ← no sub-agents
└──────────────────┘
```

- Sub-agent rows are indented and use a smaller font
- Status indicators: ⚙️ working, ● ready, ○ idle, ✓ task complete
- Click a sub-agent to open its chat (read-only by default, or type to send a message)
- Leader's tab shows a summary of sub-agent activity (e.g., "3 workers: 2 active, 1 idle")

### Sub-agent chat view

When you click a sub-agent:

- Shows the sub-agent's conversation history (its `converse` calls and status updates)
- Text input sends messages to the sub-agent (via its inbox)
- No mic button (sub-agents don't use voice by default)
- "Kill" button in the header to terminate the sub-agent

### Leader's orchestration view

When a leader has active sub-agents, its chat view gets an optional "Workers" panel:

- Collapsible panel showing all sub-agents and their latest status
- Quick actions: message, kill, spawn new
- Activity feed showing recent sub-agent messages

## Hub Implementation

### Session model changes

```python
@dataclass
class Session:
    # ... existing fields ...
    parent_session_id: str | None = None  # set for sub-agents
    worker_sessions: list[str] = field(default_factory=list)  # leader's sub-agents
    task_description: str = ""  # what the sub-agent is working on
    is_worker: bool = False
```

### New API endpoints

- `POST /api/sessions/{session_id}/workers` — Spawn a worker (called by hub internally when leader uses `spawn_worker`)
- `GET /api/sessions/{session_id}/workers` — List workers for a session
- `DELETE /api/sessions/{session_id}/workers/{worker_name}` — Kill a worker

### Message routing

The existing `send_message` / `check_inbox` system handles all communication:

- Leader → sub-agent: `send_message("Sky-A", "...")`
- Sub-agent → leader: `send_message("Sky", "...")`
- Sub-agent → sub-agent: Not directly supported (go through the leader)
- User → sub-agent: Browser types into sub-agent chat → hub queues as inbox message

## Resource Limits

- **Max sub-agents per leader**: 4 (letters A-D). Prevents runaway spawning.
- **Max total sub-agents**: 14 (2 per leader average). Keeps system resources manageable.
- **Idle timeout**: Sub-agents auto-terminate after 30 minutes of no activity.
- **Context isolation**: Each sub-agent gets its own Claude Code session with its own context window. No shared memory between sub-agents (communicate via messages).

## Workflow Example

**User says to Sky**: "I need the auth module refactored to JWT, the API docs updated, and the test suite running."

**Sky's response flow:**

1. Sky calls `spawn_worker("Refactor auth module from session tokens to JWT. Update auth.py, middleware.py, and login route.")`
2. Sky calls `spawn_worker("Update API documentation in docs/api.md to reflect new JWT auth endpoints.")`
3. Sky calls `spawn_worker("Run the full test suite, fix any failing tests related to auth changes.")`
4. Sky tells the user: "I've kicked off three workers — Sky-A is on the auth refactor, Sky-B is updating docs, and Sky-C will run tests once A is done."
5. Sky periodically calls `list_workers()` and `check_inbox()` to monitor progress
6. When Sky-A finishes, Sky tells Sky-C: "Auth refactor is done, you can run the tests now."
7. When all workers report completion, Sky summarizes results to the user

## Patterns from Claude Code Teams

| Claude Code Pattern | Our Adaptation |
|---|---|
| **Hub-and-spoke messaging** — All communication goes through the team lead. | Same. Leaders route between workers. |
| **Task list coordination** — Shared task list with pending/in_progress/completed states. | Workers use `task_description` field. Leaders track via `list_workers`. |
| **Plan mode approval** — Leader can require workers to submit a plan first. | Future consideration. Add `require_plan` flag later. |
| **Graceful shutdown** — Leader sends request, worker responds with approve/deny. | We support both graceful (message) and forceful (`kill_worker`). |
| **Context isolation** — Each teammate gets its own context window. | Same. Communication only via hub messages. |
| **No nested teams** — Single level of hierarchy only. | Same. Workers cannot spawn sub-workers. |

**Key difference**: Claude Code uses file-based coordination (JSONL inboxes, task directories). We use the hub as a real-time WebSocket message broker — immediate delivery, browser UI updates, and voice integration.

## Implementation Order

1. Hub-side session model — Add `parent_session_id`, `worker_sessions`, `is_worker` to Session
2. `spawn_worker` MCP tool — Create worker tmux sessions with CLAUDE.md and .mcp.json
3. `list_workers` / `kill_worker` MCP tools — Leader management
4. `message_worker` / `broadcast_workers` MCP tools — Communication via inbox system
5. Browser UI: sub-agent tabs — Nested display in sidebar
6. Browser UI: worker chat view — Chat with text input
7. Browser UI: orchestration panel — Worker summary in leader's chat
8. Auto-cleanup and resource limits — Idle timeout, max workers, cascade termination
