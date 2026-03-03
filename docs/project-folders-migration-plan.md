# Project Folders — Safe Migration Plan

**Author:** Onyx
**Date:** 2026-03-03
**Status:** Draft — awaiting review

## Goal

Multi-project workspaces where each project gets its own isolated set of agents, history, and data. Users can create multiple projects (e.g., "default", "zeuldocs", "clawmux-v2"), each with up to 7 agents.

## Critical Constraint

**Claude Code ties sessions to their exact working directory path.** Session JSONL files in `~/.claude/projects/` are keyed by the directory path. Moving a live session directory breaks everything — the agent loses bash, tools, and context. This is non-negotiable.

## Architecture

### Directory Layout

```
/tmp/voice-hub-sessions/
├── af_sky/          # ← "default" project (flat, legacy)
├── am_onyx/
├── ...
├── zeuldocs/        # ← named project
│   ├── af_sky/
│   ├── am_onyx/
│   └── ...
└── clawmux-v2/     # ← another named project
    ├── af_sky/
    └── ...
```

The flat layout (`/tmp/voice-hub-sessions/{voice_id}`) continues to work as the **implicit "default" project**. Named projects live in subdirectories. No migration of existing directories ever happens.

### Data Layout

```
data/
├── history/
│   ├── af_sky.json              # ← default project (legacy, unchanged)
│   ├── am_onyx.json
│   ├── default/                 # ← full history (legacy, unchanged)
│   │   ├── af_sky.json
│   │   └── am_onyx.json
│   ├── zeuldocs/                # ← named project history
│   │   ├── af_sky.json
│   │   └── am_onyx.json
│   └── zeuldocs/default/        # ← named project full history
│       ├── af_sky.json
│       └── am_onyx.json
└── projects.json                # ← project registry
```

### projects.json

```json
{
  "projects": {
    "default": {
      "name": "Default",
      "created": "2026-03-03T00:00:00Z",
      "session_dir": "/tmp/voice-hub-sessions",
      "flat_layout": true
    },
    "zeuldocs": {
      "name": "ZeulDocs",
      "created": "2026-03-03T12:00:00Z",
      "session_dir": "/tmp/voice-hub-sessions/zeuldocs",
      "flat_layout": false
    }
  },
  "active_project": "default"
}
```

## Code Changes

### 1. project_manager.py (NEW)

```python
class ProjectManager:
    """Manages project CRUD and active project switching."""

    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.projects_file = data_dir / "projects.json"
        self.projects = self._load()

    def _load(self) -> dict:
        if self.projects_file.exists():
            return json.loads(self.projects_file.read_text())
        # Bootstrap: create implicit default project
        return {
            "projects": {
                "default": {
                    "name": "Default",
                    "created": datetime.now().isoformat(),
                    "session_dir": str(SESSION_DIR_BASE),
                    "flat_layout": True,
                }
            },
            "active_project": "default",
        }

    def create_project(self, slug: str, name: str) -> dict:
        """Create a new project. Does NOT touch existing sessions."""
        if slug in self.projects["projects"]:
            raise ValueError(f"Project '{slug}' already exists")
        session_dir = SESSION_DIR_BASE / slug
        session_dir.mkdir(parents=True, exist_ok=True)
        project = {
            "name": name,
            "created": datetime.now().isoformat(),
            "session_dir": str(session_dir),
            "flat_layout": False,
        }
        self.projects["projects"][slug] = project
        self._save()
        return project

    def switch_project(self, slug: str) -> None:
        """Switch active project. Does NOT restart or move any sessions."""
        if slug not in self.projects["projects"]:
            raise ValueError(f"Project '{slug}' not found")
        self.projects["active_project"] = slug
        self._save()

    def get_session_dir(self, project_slug: str, voice_id: str) -> Path:
        """Get the work directory for a voice in a project."""
        project = self.projects["projects"][project_slug]
        if project.get("flat_layout"):
            return SESSION_DIR_BASE / voice_id
        return Path(project["session_dir"]) / voice_id

    def get_active_project(self) -> str:
        return self.projects.get("active_project", "default")
```

### 2. session_manager.py (MODIFY)

Changes:
- `SESSION_DIR_BASE` calculation now goes through `ProjectManager.get_session_dir()`
- `spawn_session()` accepts optional `project` parameter (defaults to active project)
- `cleanup_stale_sessions()` scans all project directories, not just the flat base
- Session ID format: `voice-{name}` for default, `{project}-{name}` for named projects
- tmux session naming: same as session ID

### 3. history_store.py (MODIFY)

Changes:
- `_path()` accepts optional `project` parameter
- For default project: unchanged (`data/history/{voice_id}.json`)
- For named projects: `data/history/{project}/{voice_id}.json`
- Full history follows same pattern with `/default/` subdirectory

### 4. hub.py (MODIFY)

Changes:
- Initialize `ProjectManager` alongside `SessionManager`
- New API endpoints:
  - `GET /api/projects` — list all projects
  - `POST /api/projects` — create a new project
  - `POST /api/projects/{slug}/activate` — switch active project
  - `DELETE /api/projects/{slug}` — delete a project (terminates its sessions first)
- Existing endpoints work unchanged (they operate on the active project)

### 5. hub_mcp_server.py (MODIFY)

Changes:
- Add `set_project` and `list_projects` MCP tools for agents

## Migration Strategy: Blue-Green

### Phase 1: Add project awareness (backward compatible)

1. Add `ProjectManager` with the implicit "default" project
2. All existing behavior is unchanged — default project uses flat layout
3. No directories are moved or renamed
4. Deploy and verify everything still works identically

### Phase 2: Enable project creation

1. Add API endpoints and UI for creating new projects
2. New projects get their own subdirectory under `/tmp/voice-hub-sessions/`
3. New projects spawn fresh agents — no migration from default
4. Users can switch between projects in the UI

### Phase 3: Optional history copy (NOT move)

1. When creating a new project, optionally COPY history from an existing project
2. Original history remains untouched
3. New project gets independent copies that diverge from that point

### Phase 4: Decommission old flat-layout agents

After confirming the new project-based agents are working correctly and all desired history has been transferred:

1. **Verify new agents are stable** — all project-based agents can start, resume, converse, and message each other
2. **Verify history is transferred** — spot-check that conversation history in the new project matches the originals
3. **Terminate old flat-layout sessions** — kill tmux sessions for the old `voice-{name}` agents
4. **Clean up old state files** — remove `.session.json` and `.mcp.json` from flat-layout voice dirs
5. **Archive old session directories** — move `/tmp/voice-hub-sessions/{voice_id}/` to `/tmp/voice-hub-sessions/.archive/{voice_id}/` (not delete — keep as safety net)
6. **Archive old history** — copy `data/history/{voice_id}.json` and `data/history/default/{voice_id}.json` to `data/archive/default/`
7. **Update projects.json** — mark the "default" project as `"decommissioned": true` or remove it
8. **Clean Claude Code session data** — remove the old `~/.claude/projects/-tmp-voice-hub-sessions-{voice_id}/` directories (these are the JSONL transcripts keyed to the old paths)
9. **Update hub config** — if the flat layout is fully decommissioned, the new project becomes the new "default"

**Safety net:** Keep the `.archive/` directories for at least 7 days before permanent deletion. If anything breaks, restore from archive by moving directories back and reverting `projects.json`.

**DO NOT run Phase 4 until:**
- All agents in the new project have been running stable for at least 24 hours
- User has explicitly confirmed the new project works correctly
- No active work is in progress on the old agents

### Switching Projects (Runtime)

When the user switches from project A to project B:

1. **DO NOT** terminate project A's sessions
2. Project A's agents stay alive in their tmux sessions
3. The browser disconnects from project A's active agent
4. The browser connects to project B's active agent (spawning if needed)
5. The sidebar shows project B's agents
6. User can switch back to A at any time — sessions are still running

### Decommissioning a Project

When the user deletes a project:

1. Terminate all sessions in that project (kill tmux, clean state files)
2. Optionally archive history (move to `data/archive/{project}/`)
3. Remove project from `projects.json`
4. Remove the project's session directory

## Rollback Procedures

### If Phase 1 breaks anything:
- Revert the code changes (git checkout the server files)
- Restart the hub — it falls back to flat layout since no `projects.json` exists
- All existing sessions resume normally (directories were never moved)

### If Phase 2 breaks anything:
- Delete the named project's session directory
- Remove the project from `projects.json`
- Restart the hub — default project continues working

### General principle:
- The "default" project is always the flat layout
- The flat layout never changes
- Named projects are fully independent — deleting them has zero impact on default

## What We Will NOT Do

1. **Auto-migrate on hub startup** — This was the critical mistake. Never again.
2. **Move live session directories** — Claude Code breaks. Period.
3. **Rename tmux sessions** — Running agents depend on their tmux session name.
4. **Change the default project layout** — Flat layout is permanent for backward compatibility.
5. **Force users into projects** — Projects are opt-in. Default works forever.

## Testing Plan

1. Deploy Phase 1 — verify all 7 agents start, resume, and work identically
2. Create a test project — verify agents spawn in the new subdirectory
3. Switch between default and test project — verify both sets of agents stay alive
4. Delete the test project — verify default is unaffected
5. Restart the hub — verify default sessions adopt correctly, deleted project stays gone
