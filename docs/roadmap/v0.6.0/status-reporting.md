# Status Reporting

The hub has no visibility into agent activity between `converse()` calls. The browser shows "Ready" even when the agent is working.

## Working State

After `converse()` returns, the session transitions to "Working" instead of "Ready." State flow:

```
Listening → Transcribing → Speaking → Working → Listening
```

## `report_status` Tool

Agents call `report_status("Reading files...")` to push live updates to the browser. The hub forwards these as WebSocket `status` events.

## Idle Detection

No `converse()` or `report_status()` within 60 seconds → status shows "Idle."

## Compaction Detection

When Claude Code compacts its context, the agent goes silent. Options: poll tmux output for compaction text, use Claude Code hooks if available, or fall back to a timeout heuristic. Browser shows "Compacting..." with a distinct indicator.
