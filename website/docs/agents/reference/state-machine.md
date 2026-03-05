# Agent State Machine

ClawMux tracks each agent's lifecycle through a single canonical state enum, plus an orthogonal `status_text` string that describes what the agent is currently doing.

## State Enum

```python
class AgentState(str, Enum):
    STARTING   = "starting"
    IDLE       = "idle"
    PROCESSING = "processing"
    COMPACTING = "compacting"
    DEAD       = "dead"
```

| State | Description |
|-------|-------------|
| **STARTING** | Agent spawned, Claude booting. Stays here until the first `clawmux wait` connects. |
| **IDLE** | Agent is in `clawmux wait`, blocked waiting for a message. |
| **PROCESSING** | Agent is actively working (reading files, running commands, thinking). |
| **COMPACTING** | Claude is compacting its context window. Agent is temporarily unavailable. |
| **DEAD** | Session terminated. |

## Status Text

`status_text` is a free-form string that describes the agent's current activity. It is **orthogonal** to the state enum — it persists across state transitions and is only overwritten explicitly.

**Defaults per state:**

| State | Default status_text |
|-------|-------------------|
| STARTING | *(empty)* |
| IDLE | `Waiting` |
| PROCESSING | `Processing...` (then overwritten by PreToolUse with the tool name) |
| COMPACTING | `Compacting context...` |
| DEAD | *(empty)* |

Examples of status_text during PROCESSING: `Reading hub.py`, `Running git status`, `Editing server/hub.py`.

During IDLE, status_text shows the last tool the agent ran (e.g., `Running clawmux wait`), giving users visibility into what the agent was doing before it went idle.

## State Transitions

```
                  ┌─────────────────────────────────┐
                  │                                  │
                  ▼                                  │
             STARTING ──wait WS connects──► IDLE ◄──┘
                  │                          │  ▲
                  │                          │  │
               terminate               wait WS  wait WS
                  │                     disconnects connects
                  │                          │  │
                  ▼                          ▼  │
                DEAD ◄──terminate──── PROCESSING
                  ▲                          │  ▲
                  │                          │  │
               terminate              PreCompact PreToolUse
                  │                          │  │
                  │                          ▼  │
                  └──────terminate──── COMPACTING
```

### Transition Table

| From | To | Trigger |
|------|----|---------|
| STARTING | IDLE | First wait WebSocket connects |
| IDLE | PROCESSING | Wait WebSocket disconnects |
| PROCESSING | IDLE | Wait WebSocket connects |
| PROCESSING | COMPACTING | PreCompact hook fires |
| COMPACTING | IDLE | Wait WebSocket connects |
| COMPACTING | PROCESSING | PreToolUse hook fires |
| *any* | DEAD | Session terminated |

### The Wait WebSocket

The wait WebSocket (`clawmux wait`) is the **single source of truth** for IDLE/PROCESSING transitions:

- **Connect** = agent entered `clawmux wait` = **IDLE**
- **Disconnect** = agent left `clawmux wait` (received a message, started working) = **PROCESSING**

No other mechanism transitions between IDLE and PROCESSING. Hook events like `Stop`, `PostToolUse`, and `SessionStart` do **not** change the state.

## Hook Behavior

| Hook | State Change | status_text Change |
|------|-------------|-------------------|
| **SessionStart** | None (stays STARTING) | `Starting session...` |
| **PreToolUse** | COMPACTING → PROCESSING | Set to tool description (e.g., `Reading hub.py`) |
| **PostToolUse** | None | None (preserves last tool name) |
| **Stop** | None | None |
| **PreCompact** | → COMPACTING | `Compacting context...` |

Key design decisions:

- **SessionStart** does not transition to PROCESSING — the agent stays STARTING until it first calls `clawmux wait`.
- **PostToolUse** and **Stop** do not transition to IDLE — the agent is still PROCESSING until it calls `clawmux wait`.
- **PreToolUse** escapes COMPACTING because it proves Claude resumed tool execution after compaction.
- **status_text is never cleared on PostToolUse** — it persists so IDLE can display the last activity.

## Browser Display

### Sidebar

The sidebar reflects **server state only**. No browser-only states (speaking, listening) appear on the sidebar.

| Server State | Sidebar Indicator |
|-------------|-------------------|
| STARTING | Starting (yellow) |
| IDLE | Idle (green) |
| PROCESSING | Working (blue) |
| COMPACTING | Working (blue) |
| DEAD | Offline (gray) |

### Chat Area

| Server State | Chat Display |
|-------------|-------------|
| IDLE | Muted status text showing `status_text` (e.g., "Running clawmux wait") |
| PROCESSING | Thinking indicator with animated dots |
| COMPACTING | Thinking indicator with animated dots |
| STARTING | Nothing (session initializing) |

### Browser-Only States

**Speaking** (TTS playback) is tracked only in the browser. It does not appear on the sidebar or affect the server state. The speaking indicator appears near the mic/recording button area only.

**Listening** (mic recording) is also browser-only. On the sidebar, listening maps to idle.

## Implementation

State is managed by `set_state()` on the session object in `session_manager.py`. This method updates the canonical `state` field and syncs deprecated boolean flags (`processing`, `in_wait`, `compacting`, `status`) for backward compatibility.

```python
def set_state(self, new_state: AgentState) -> None:
    self.state = new_state
    # Sync deprecated fields...
```

State changes are broadcast to the browser via `session_status` WebSocket messages that include the `state` field. The browser reads `data.state` and maps it to UI states.
