# Orchestration Reference

Implementation details for sub-agent orchestration. For the high-level design, see the [v0.6.0 roadmap](../../roadmap/v0.6.0/sub-agent-orchestration.md).

## Session Model

```python
@dataclass
class Session:
    # ... existing fields ...
    parent_session_id: str | None = None  # set for workers
    worker_sessions: list[str] = field(default_factory=list)
    task_description: str = ""
    is_worker: bool = False
```

## Spawn Flow

1. Leader calls `spawn_worker("Refactor auth to JWT")`
2. Hub creates work dir at `/tmp/clawmux-sessions/{leader_voice}/workers/{name}/`
3. Hub writes `.mcp.json` with new `CLAWMUX_SESSION_ID`
4. Hub writes `CLAUDE.md` with worker identity and task
5. Hub starts tmux session `voice-{leader}-{letter}` and launches Claude Code
6. Claude loads MCP server, connects to hub
7. Hub sends `worker_spawned` to browser → sub-tab appears
8. Worker reads task from CLAUDE.md and begins work
9. Worker uses `report_status` and `send_message` to communicate progress

## Worker CLAUDE.md Template

```markdown
You are {Leader}-{Letter}, a worker for {Leader}.

Task: {task_description}

Report progress with `report_status`. When done, send results to {Leader} with `send_message`.
```

## Message Routing

- Leader → worker: `send_message("Sky-A", "...")`
- Worker → leader: `send_message("Sky", "...")`
- Worker → worker: Not direct (route through leader)
- User → worker: Browser chat → hub queues as inbox message

## API Endpoints

- `POST /api/sessions/{id}/workers` — Spawn (called internally by `spawn_worker`)
- `GET /api/sessions/{id}/workers` — List workers
- `DELETE /api/sessions/{id}/workers/{name}` — Kill worker

## Resource Limits

| Limit | Value | Rationale |
|-------|-------|-----------|
| Max per leader | 4 (A-D) | Prevent runaway spawning |
| Max total | 14 | System resource budget |
| Idle timeout | 30 min | Auto-cleanup |

## Workflow Example

User says to Sky: "Refactor auth to JWT, update docs, and run tests."

1. Sky spawns Sky-A (auth refactor), Sky-B (docs), Sky-C (tests)
2. Sky tells user: "Three workers on it."
3. Sky monitors via `list_workers` and `check_inbox`
4. When Sky-A finishes, Sky tells Sky-C to run tests
5. All done → Sky summarizes results to user

## Claude Code Teams Comparison

| Claude Code | ClawMux |
|---|---|
| Hub-and-spoke messaging | Same — leaders route |
| File-based coordination (JSONL) | WebSocket message broker |
| Task list with states | `task_description` + `list_workers` |
| Plan mode approval | Future consideration |
| Context isolation per teammate | Same — separate Claude sessions |
| Single-level hierarchy | Same — no nested workers |
