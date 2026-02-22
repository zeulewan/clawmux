# Agent Status Reporting

Currently, the hub has no visibility into what an agent is doing between `converse()` calls. The browser shows "Ready" even when the agent is actively reading files, running tests, or writing code. This makes the system feel unresponsive.

## "Working" State

After a `converse()` call returns text to the agent, the hub transitions the session to "Working..." instead of "Ready." This gives the user immediate feedback that the agent received their input and is processing it.

The hub tracks state transitions:

```
Listening → Transcribing → Speaking → Working → Listening (next cycle)
```

"Working" persists until the next `converse()` or `report_status()` call.

## `report_status` Tool

New MCP tool that lets agents tell the hub what they're doing:

```python
@mcp.tool
async def report_status(status: str) -> str:
    """Report current activity to the hub for display in the browser.

    Args:
        status: Short description of current activity (e.g., "Reading files...", "Running tests...")

    Returns:
        Confirmation message.
    """
```

The hub forwards the status to the browser via WebSocket:

```json
{"type": "status", "session_id": "voice-sky", "text": "Reading files..."}
```

Agents call this naturally during their work — no special prompting needed. The `/voice-hub` skill can include instructions to call `report_status` between converse cycles.

## Status Timeout

If no `converse()` or `report_status()` call arrives within **60 seconds**, the browser shows "Idle" with a dimmed indicator. This distinguishes between:

- **Working** — Agent is actively doing something (recent `report_status`)
- **Idle** — Agent hasn't communicated recently (may be stuck or finished)
- **Ready** — Agent is initialized but hasn't started yet
- **Listening** — Waiting for user voice input

## Compaction Detection

When Claude Code's context window gets full, it automatically compacts (summarizes) the conversation. During compaction, the agent can't process requests — but the browser has no way to know this is happening.

Possible approaches:

- **tmux polling** — Hub periodically checks the tmux pane output for compaction-related text (e.g., "Compacting conversation..."). Fragile but doesn't require Claude Code changes.
- **Claude Code hooks** — If Claude Code supports lifecycle hooks (e.g., `on_compact`), the MCP server could intercept the event and notify the hub.
- **Timeout heuristic** — If an agent goes silent for longer than expected (e.g., 30+ seconds with no tool calls or output), show a "Compacting..." status.

The browser would show "Compacting..." with a distinct indicator (e.g., purple dot) so users know the agent is temporarily unavailable, not stuck.
