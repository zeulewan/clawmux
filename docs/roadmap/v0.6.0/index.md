# v0.6.0 - Agent Orchestration

MCP server overhaul and sub-agent orchestration. Rethink how agents communicate with the hub and each other, add real-time status reporting, and enable leaders to spawn and manage worker sub-agents.

## Sections

- [Agent Status Reporting](status-reporting.md) — Working state, `report_status` tool, idle detection
- [Message Queuing](message-queuing.md) — User messages while agent works, queue indicator, `check_inbox`
- [Inter-Agent Communication](inter-agent-communication.md) — `list_agents`, `send_message`, message delivery via converse
- [Sub-Agent Orchestration](sub-agent-orchestration.md) — Leader/worker hierarchy, spawn/kill/message workers, browser UI

## Checklist

### Status Reporting
- [ ] "Working" state after converse returns
- [ ] `report_status` MCP tool
- [ ] Status timeout → "Idle"
- [ ] Compaction detection (show "Compacting..." in sidebar)

### Message Queuing
- [ ] Queue user messages while agent works
- [ ] Queue indicator in browser
- [ ] `check_inbox` MCP tool

### Inter-Agent Communication
- [ ] `list_agents` MCP tool
- [ ] `send_message(target, message)` MCP tool
- [ ] `check_inbox` for inter-agent messages
- [ ] Message delivery bundled into converse results

### Sub-Agent Orchestration
- [ ] Session model: `parent_session_id`, `worker_sessions`, `is_worker`
- [ ] `spawn_worker` MCP tool
- [ ] `list_workers` / `kill_worker` MCP tools
- [ ] `message_worker` / `broadcast_workers` MCP tools
- [ ] Browser UI: nested sub-agent tabs
- [ ] Browser UI: worker chat view
- [ ] Browser UI: leader orchestration panel
- [ ] Auto-cleanup and resource limits
