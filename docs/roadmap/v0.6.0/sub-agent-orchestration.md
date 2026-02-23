# Sub-Agent Orchestration

Each main agent (Sky, Alloy, Adam, etc.) is a **leader** that can spawn **workers** — lightweight sub-agents that inherit the leader's voice and appear nested in the UI.

## Hierarchy

```
Hub
├── Sky (leader)
│   ├── Sky-A (working on "refactor auth")
│   └── Sky-B (running tests)
├── Alloy (leader)
│   └── Alloy-A (updating docs)
└── Adam (leader, no workers)
```

Workers use naming convention `{Leader}-{letter}` (Sky-A, Sky-B). Max 4 workers per leader, 14 total. Idle workers auto-terminate after 30 minutes.

## Leader Tools

| Tool | Purpose |
|------|---------|
| `spawn_worker(task)` | Create a worker with a task description |
| `list_workers` | Check worker names, status, tasks |
| `kill_worker(name)` | Forcefully terminate a worker |
| `message_worker(name, msg)` | Send a message to one worker |
| `broadcast_workers(msg)` | Message all workers |

Workers get `converse`, `report_status`, `send_message`, and `check_inbox` but cannot spawn their own workers.

## Browser UI

- Workers appear indented under their leader in the sidebar with status icons
- Click a worker to see its conversation and send text messages
- Leader's chat shows a collapsible "Workers" panel with status and quick actions
- No mic button on worker chats (text-only by default)

## Termination

- **Graceful**: Leader messages the worker to wrap up
- **Forceful**: `kill_worker` kills the tmux session immediately
- **Cascade**: Terminating a leader kills all its workers

## Design Notes

Single-level hierarchy only — workers cannot spawn sub-workers. All communication routes through the hub's message system (same `send_message` / `check_inbox` used for inter-agent communication). See the [agents reference](../../agents/reference/orchestration.md) for implementation details.
