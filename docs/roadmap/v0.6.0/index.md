# v0.6.0 - Agent Orchestration

Dual-backend architecture supporting both OpenClaw and Claude Code (tmux), with agent orchestration, status reporting, and inter-agent communication.

## Sections

- [Dual Backend](dual-backend.md) — OpenClaw as primary backend, Claude Code/tmux as legacy option
- [Agent Status Reporting](status-reporting.md) — Working state, `report_status` tool, idle detection
- [Message Queuing](message-queuing.md) — User messages while agent works, queue indicator, `check_inbox`
- [Inter-Agent Communication](inter-agent-communication.md) — `list_agents`, `send_message`, message delivery via converse
- [Sub-Agent Orchestration](sub-agent-orchestration.md) — Leader/worker hierarchy, spawn/kill/message workers, browser UI
- [Public API](api.md) — REST + WebSocket protocol, auth, versioning, integration guide

## Checklist

### Dual Backend
- [ ] Abstract session backend interface (OpenClaw vs tmux)
- [ ] OpenClaw Gateway integration (WebSocket client)
- [ ] OpenClaw multi-agent routing for named voices
- [ ] Keep tmux/Claude Code as fallback mode
- [ ] Frontend modular enough to support both backends

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

### Public API
- [ ] Token-based authentication
- [ ] `/v1/` REST endpoint versioning
- [ ] Agent management endpoints (`/v1/agents`)
- [ ] New WebSocket events (worker lifecycle, agent status)
