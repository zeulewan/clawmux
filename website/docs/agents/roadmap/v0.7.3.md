# v0.7.3 — Flat Architecture & Centralized State

Simplify the session layout to flat agent directories with centralized metadata. Replace per-agent state files with a single `agents.json` managed by the hub.

## Core Decisions

1. **Flat agent directories** — all 27 agents live in one folder, no project nesting
2. **Centralized `agents.json`** — hub holds all agent metadata in one file
3. **Projects = logical groupings** — agents freely move between projects
4. **Template-based CLAUDE.md** — one template, rendered per-agent, regenerated on changes
5. **27 agent cap** from the voice pool, expandable later
6. **Backend abstraction** — all tmux code isolated into `ClaudeCodeBackend`, hub core has zero tmux references
7. **No Direct API backend** — OpenClaw handles API calls; ClawMux focuses on UI/coordination

## Directory Layout

### Before (nested)

```
/tmp/clawmux-sessions/
├── default/
│   ├── af_sky/
│   ├── af_alloy/
│   └── ...
├── clawmux/
│   ├── af_sky/
│   └── ...
```

### After (flat, under `CLAWMUX_HOME`)

```
~/.clawmux/                          # CLAWMUX_HOME (configurable via env var)
├── sessions/
│   ├── af_sky/
│   ├── af_alloy/
│   ├── af_sarah/
│   ├── am_adam/
│   ├── am_echo/
│   ├── am_onyx/
│   ├── bm_fable/
│   └── ...  (up to 27 agents)
├── data/
│   └── agents.json
└── history/
```

Each agent gets one directory. Project assignment is metadata, not filesystem structure. All runtime data lives under `CLAWMUX_HOME` (default `~/.clawmux`, configurable via `CLAWMUX_HOME` env var).

## Data Model: `agents.json`

Centralized file at `$CLAWMUX_HOME/data/agents.json`, managed exclusively by the hub. Replaces per-agent `.session.json` and `.project_status.json` files.

```json
{
  "agents": {
    "af_sky": {
      "session_id": "sky-abc123",
      "project": "clawmux",
      "role": "manager",
      "area": "frontend",
      "last_active": 1709500000,
      "model": "opus",
      "state": "idle",
      "backend": "claude-code"
    },
    "am_echo": {
      "session_id": "echo-def456",
      "project": "clawmux",
      "role": "worker",
      "area": "backend",
      "last_active": 1709500100,
      "model": "opus",
      "state": "processing",
      "backend": "claude-code"
    }
  },
  "projects": {
    "clawmux": {
      "display_name": "ClawMux",
      "created_at": 1709500000
    },
    "openclaw": {
      "display_name": "OpenClaw",
      "created_at": 1709500200
    }
  }
}
```

### Data Model Comparison

| Approach | Current (per-agent files) | v0.7.3 (centralized) |
|---|---|---|
| Storage | `.session.json` + `.project_status.json` per agent | Single `agents.json` |
| Write safety | Race conditions between hub and agents | All writes go through hub API |
| Reads | Scan directories + parse multiple files | Single file read |
| Consistency | Can diverge (stale files, orphaned state) | Single source of truth |
| Monitor | Scans project directories | Reads `agents.json` directly |
| Migration | Complex (move dirs, update paths) | Update metadata field |

## CLAUDE.md Template

One template rendered with agent-specific variables. Regenerated automatically when role, project, or managers change.

```markdown
# {name}

You are {name}, a {role} agent on the ClawMux hub.

## Project
Current project: **{project}**
Area: {area}

## Team
{managers_section}

## Rules
{role_specific_rules}
```

Variables:

| Variable | Source |
|---|---|
| `{name}` | Agent display name (e.g. "Echo") |
| `{role}` | From `agents.json` (manager, worker, researcher) |
| `{project}` | Current project assignment |
| `{area}` | Sub-area within project (frontend, backend, docs) |
| `{managers_section}` | Generated from project's manager list |
| `{role_specific_rules}` | Injected based on role (e.g. managers get delegation rules) |

## New Project Flow

1. User creates project (UI or CLI)
2. Hub pre-populates with 6 agents: 2 managers + 4 workers
3. Default assignment configurable via `data/project-defaults.json`
4. CLAUDE.md regenerated for all assigned agents
5. Agents not yet spawned — lazy spawning on first interaction

### Default Configuration

```json
{
  "default_agents": {
    "managers": ["af_sky", "af_sarah"],
    "workers": ["af_alloy", "am_adam", "am_echo", "am_onyx"]
  }
}
```

## Tmux Session Names

Simplified from `voice-{project}-{name}` to just the agent name:

| Before | After |
|---|---|
| `voice-clawmux-sky` | `sky` |
| `voice-default-echo` | `echo` |

Since agents are no longer project-namespaced in the filesystem, tmux names don't need project prefixes.

## Agent Movement

Agents can freely move between projects:

```bash
# Via CLI
clawmux assign echo --project openclaw --area backend

# Via browser context menu
# Right-click agent → Move to Project → [project list]
```

On assignment change:
1. Update `agents.json`
2. Regenerate CLAUDE.md with new project/role context
3. Agent continues in same tmux session (no restart needed)

## Monitor

The monitor pane reads from `agents.json` instead of scanning project directories:

- Faster startup (no directory traversal)
- Accurate state (single source of truth)
- Project grouping is a display concern, not filesystem

## Legacy Coexistence

During migration, both layouts coexist:

- **Old nested layout** — existing project directories remain functional
- **New flat layout** — new agents use flat directories
- **Hub detects both** — `cleanup_stale_sessions` checks both layouts
- **Migration path** — agents gradually move to flat layout on next spawn

**CRITICAL:** Never move a live session directory. Claude Code sessions are tied to their exact working directory path.

## Concurrent Write Safety

All metadata writes go through the hub API:

- `PUT /api/agents/{voice_id}` — update agent metadata
- `POST /api/agents/{voice_id}/assign` — change project/role
- Hub holds write lock on `agents.json`
- Agents never write metadata directly — only the hub does
- CLI commands (`clawmux assign`, `clawmux project`) go through the API

## Implementation Steps

### Phase 1: Centralized State

1. Create `agents.json` schema and read/write in hub
2. Migrate `SessionManager` to read/write from `agents.json`
3. Remove per-agent `.session.json` and `.project_status.json` writes
4. Update `cleanup_stale_sessions` to populate `agents.json` on adopt

### Phase 2: Flat Layout

1. New agents spawn into flat directories
2. Update tmux naming to simple agent names
3. Legacy nested directories still work (backward compat)
4. Monitor reads from `agents.json`

### Phase 3: CLAUDE.md Templates

1. Create template system with variable substitution
2. Regenerate CLAUDE.md on role/project changes
3. Role-specific rule injection

### Phase 4: Project Management

1. New project flow with pre-populated agents
2. Agent assignment UI (context menu + CLI)
3. Project defaults configuration
4. Dynamic sidebar grouping by project

## Backend Abstraction

All session management (spawn, terminate, health check, message delivery) is abstracted behind an `AgentBackend` interface. The hub core has zero tmux references.

### Directory Structure

```
server/backends/
├── __init__.py
├── base.py              # Abstract AgentBackend class
├── claude_code.py       # ClaudeCodeBackend (tmux + hooks)
├── openclaw.py          # OpenClawBackend (Gateway WebSocket)
└── generic_cli.py       # GenericCLIBackend (tmux + configurable hooks)
```

### Abstract Interface

```python
class AgentBackend:
    async def spawn(self, voice_id: str, work_dir: Path, config: dict) -> str:
        """Spawn an agent session. Returns session_id."""
        ...

    async def terminate(self, session_id: str) -> None:
        """Terminate an agent session."""
        ...

    async def health_check(self, session_id: str) -> bool:
        """Check if session is alive."""
        ...

    async def deliver_message(self, session_id: str, message: dict) -> None:
        """Deliver a message to the agent."""
        ...

    async def restart(self, session_id: str) -> str:
        """Restart the agent (e.g., model change). Returns new session_id."""
        ...
```

### Planned Backends

| Backend | Transport | Use Case |
|---|---|---|
| `ClaudeCodeBackend` | tmux + Claude Code hooks | Current default. Wraps all existing tmux code. |
| `OpenClawBackend` | Gateway WebSocket | Primary alternative. Delegates API calls to OpenClaw. |
| `GenericCLIBackend` | tmux + configurable hooks | For tools like OpenCode, Aider, or other CLI agents. |

**No Direct API backend** — OpenClaw handles direct Anthropic API calls. ClawMux focuses on UI, coordination, and voice. This avoids duplicating API management logic.

### Tmux Compartmentalization

All tmux operations are isolated to `ClaudeCodeBackend`:

- `_spawn_tmux()`, `_cleanup_tmux()`, `_apply_agent_status_bar()`
- `_run()` (shell command execution)
- Tmux session naming and health checks
- Hook installation and inbox file management

The hub's `SessionManager` calls backend methods only — never tmux directly. This makes tmux a swappable implementation detail.

## Header Cleanup

Rename `X-ClawMux-Session` header to `ClawMux-Session` (drop deprecated `X-` prefix per RFC 6648).
