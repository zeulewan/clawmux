# v0.7.3 Implementation Roadmap

Step-by-step plan for the flat architecture refactor. Each phase is independently testable and rollback-safe.

---

## Phase 1: Centralized `agents.json` (Data Layer)

**Goal:** Replace per-agent `.session.json` and `.project_status.json` with a single `agents.json` managed by the hub, while keeping the existing filesystem layout unchanged.

### Steps

- [ ] **1.1** Create `data/agents.json` schema validation (Pydantic or JSON Schema)
  - Define `AgentEntry` and `ProjectEntry` models matching the spec
  - Validate on read/write to catch corruption early

- [ ] **1.2** Add `AgentsStore` class to hub (`server/agents_store.py`)
  - `load()` — read `data/agents.json`, create if missing
  - `save()` — atomic write (write to `.tmp`, then `os.replace`)
  - `get(voice_id)` / `set(voice_id, data)` / `remove(voice_id)`
  - `get_project(slug)` / `set_project(slug, data)`
  - Write lock via `asyncio.Lock` (single hub process)

- [ ] **1.3** Dual-write in `SessionManager`
  - On `spawn_session()`: write both `.session.json` AND `agents.json`
  - On `set_project_status()`: write both `.project_status.json` AND `agents.json`
  - On `cleanup_stale_sessions()`: populate `agents.json` from adopted sessions
  - On session kill/timeout: update `agents.json` entry (clear session_id, set state=dead)

- [ ] **1.4** Add hub API endpoints for metadata
  - `GET /api/agents` — return all agents from `agents.json`
  - `GET /api/agents/{voice_id}` — return single agent
  - `PUT /api/agents/{voice_id}` — update agent metadata
  - `POST /api/agents/{voice_id}/assign` — change project/role

- [ ] **1.5** Update monitor to read from `agents.json`
  - Keep fallback to directory scanning if `agents.json` is missing/empty

### Test Checklist

- [ ] Spawn an agent, verify both `.session.json` and `agents.json` are written
- [ ] Kill an agent, verify `agents.json` is updated
- [ ] Restart hub, verify `cleanup_stale_sessions` populates `agents.json` from orphans
- [ ] `GET /api/agents` returns correct data
- [ ] Monitor displays correct agent states

### Rollback

- Delete `server/agents_store.py`
- Revert dual-write changes in `SessionManager`
- Remove API endpoints
- `agents.json` can be safely deleted — `.session.json` files are still authoritative

---

## Phase 2: Cut Over to `agents.json` as Source of Truth

**Goal:** Stop reading from per-agent state files. `agents.json` becomes the single source of truth.

### Steps

- [ ] **2.1** Switch `SessionManager` reads to `agents.json`
  - `cleanup_stale_sessions()` reads `agents.json` instead of scanning `.session.json` files
  - Agent state queries use `AgentsStore.get()` instead of file reads

- [ ] **2.2** Stop writing per-agent state files
  - Remove `.session.json` writes from `spawn_session()`
  - Remove `.project_status.json` writes from `set_project_status()`
  - Keep the files on disk (don't delete yet — safety net)

- [ ] **2.3** Update `clawmux project` CLI to use API
  - `clawmux project` calls `POST /api/agents/{voice_id}/assign` instead of writing files

- [ ] **2.4** Update browser/frontend to use `/api/agents` endpoint
  - Replace any direct `.session.json` reads (if any) with API calls

### Test Checklist

- [ ] Hub restart with only `agents.json` (delete all `.session.json` files) — agents still adopted correctly
- [ ] `clawmux project` updates `agents.json` correctly
- [ ] No `.session.json` or `.project_status.json` files created on new spawn
- [ ] Full agent lifecycle works: spawn -> process -> idle -> kill

### Rollback

- Re-enable dual-write from Phase 1 (files + `agents.json`)
- Per-agent files still exist on disk as fallback

---

## Phase 3: Flat Directory Layout

**Goal:** New agents spawn into flat directories (`/tmp/clawmux-sessions/{voice_id}/`). Existing nested sessions continue working.

### Steps

- [ ] **3.1** Introduce `CLAWMUX_HOME` base directory
  - Default: `~/.clawmux` (configurable via `CLAWMUX_HOME` env var)
  - Sessions: `$CLAWMUX_HOME/sessions/{voice_id}/`
  - Data: `$CLAWMUX_HOME/data/agents.json`
  - History: `$CLAWMUX_HOME/history/`
  - Update `SESSION_DIR_BASE` in `session_manager.py` to read from env
  - Update `hub_config.py` to export `CLAWMUX_HOME` path
  - Migrate from `/tmp/clawmux-sessions/` — detect old location and log a warning

- [ ] **3.2** Update `spawn_session()` work_dir logic
  - New sessions: `CLAWMUX_HOME / sessions / voice_id` (flat)
  - Remove project slug from directory path
  - Set `project_slug` in `agents.json` metadata only

- [ ] **3.3** Simplify tmux session naming
  - Change from `voice-{project}-{name}` to just `{name}` (e.g., `sky`, `echo`)
  - Update `TMUX_SESSION_PREFIX` usage accordingly
  - Update `cleanup_stale_sessions()` to recognize both old and new tmux name formats

- [ ] **3.4** Legacy coexistence in `cleanup_stale_sessions()`
  - Scan both flat dirs and nested project dirs for orphans
  - **CRITICAL:** Never move a live session directory — Claude Code sessions are path-bound
  - Existing nested sessions stay where they are until they die naturally
  - Only new spawns use flat layout

- [ ] **3.5** Update CLAUDE.md generation path
  - Write CLAUDE.md to `CLAWMUX_HOME / sessions / voice_id / CLAUDE.md` for flat sessions

- [ ] **3.6** Update `clawmux assign` to work with flat layout
  - Assignment changes only update `agents.json` — no directory moves
  - Regenerate CLAUDE.md in place

### Test Checklist

- [ ] `CLAWMUX_HOME` defaults to `~/.clawmux` when env var is unset
- [ ] Setting `CLAWMUX_HOME=/custom/path` puts all data under that path
- [ ] New agent spawns into `$CLAWMUX_HOME/sessions/{voice_id}/` (flat, not nested)
- [ ] `agents.json` lives at `$CLAWMUX_HOME/data/agents.json`
- [ ] Tmux session named just `sky` (not `voice-clawmux-sky`)
- [ ] Existing sessions in `/tmp/clawmux-sessions/` still adopted on restart (legacy compat)
- [ ] `clawmux assign echo --project openclaw` updates metadata without moving directories
- [ ] Agent can be reassigned between projects without restart

### Rollback

- Revert `spawn_session()` to use nested paths
- Revert tmux naming
- Flat directories already created can be left in place (harmless) or cleaned up manually
- `agents.json` still has correct metadata regardless of layout

---

## Phase 4: CLAUDE.md Template System

**Goal:** Replace hand-written per-agent CLAUDE.md with a template system. One template, rendered per-agent.

### Steps

- [ ] **4.1** Create template file (`server/templates/claude_md.template`)
  - Use simple `{variable}` substitution (or Jinja2 if complexity warrants)
  - Variables: `{name}`, `{role}`, `{project}`, `{area}`, `{managers_section}`, `{role_specific_rules}`

- [ ] **4.2** Create `TemplateRenderer` class (`server/template_renderer.py`)
  - `render(voice_id)` — reads template, fills variables from `agents.json`
  - `render_all()` — regenerate all agent CLAUDE.md files
  - Role-specific rule blocks loaded from `server/templates/rules/` (e.g., `manager.md`, `worker.md`)

- [ ] **4.3** Auto-regenerate on changes
  - On `POST /api/agents/{voice_id}/assign` — regenerate that agent's CLAUDE.md
  - On project manager change — regenerate all agents in that project
  - On template file change — regenerate all (dev convenience)

- [ ] **4.4** Add `clawmux regenerate` CLI command
  - `clawmux regenerate` — regenerate all CLAUDE.md files
  - `clawmux regenerate echo` — regenerate one agent's CLAUDE.md

- [ ] **4.5** Migrate existing CLAUDE.md content into template
  - Extract common rules (communication, formatting, hub management) into template
  - Extract role-specific rules into separate files
  - Preserve all existing behavior — this is a refactor, not a rewrite

### Test Checklist

- [ ] `clawmux regenerate echo` produces correct CLAUDE.md with echo's metadata
- [ ] Changing echo's project via `clawmux assign` auto-regenerates CLAUDE.md
- [ ] Manager section correctly lists project managers
- [ ] Role-specific rules are injected (manager gets delegation rules, worker doesn't)
- [ ] Diff existing hand-written CLAUDE.md against generated — no functional changes

### Rollback

- Keep hand-written CLAUDE.md files as backup before first generation
- Revert to manual CLAUDE.md if template output is wrong
- Template system is additive — removing it doesn't break anything

---

## Phase 5: Project Management & UI

**Goal:** New project flow, agent assignment UI, and dynamic sidebar grouping.

### Steps

- [ ] **5.1** Create `data/project-defaults.json`
  - Default manager/worker assignments for new projects
  - Configurable via CLI or UI

- [ ] **5.2** Implement new project flow
  - `clawmux project create <name>` — creates project in `agents.json`, pre-populates agents
  - Regenerate CLAUDE.md for all assigned agents
  - Agents not spawned yet — lazy spawn on first interaction

- [ ] **5.3** Agent assignment UI (browser)
  - Context menu: right-click agent -> Move to Project -> [project list]
  - Calls `POST /api/agents/{voice_id}/assign`
  - Sidebar updates dynamically (project grouping from `agents.json`)

- [ ] **5.4** Dynamic sidebar grouping
  - Sidebar groups agents by `project` field from `agents.json`
  - No filesystem dependency — purely metadata-driven
  - Unassigned agents shown in "Unassigned" group

- [ ] **5.5** Clean up legacy code
  - Remove `ProjectManager` class (replaced by `agents.json` projects)
  - Remove per-agent state file references
  - Remove nested directory support from `cleanup_stale_sessions()` (only after all old sessions are gone)

### Test Checklist

- [ ] `clawmux project create myproject` creates project with default agents
- [ ] Context menu assignment works in browser
- [ ] Sidebar groups agents by project correctly
- [ ] Creating a project does NOT spawn agents (lazy spawn)
- [ ] All 27 agents visible and manageable

### Rollback

- Revert UI changes (sidebar, context menu)
- Keep `ProjectManager` if Phase 5.5 cleanup was started
- `agents.json` remains valid regardless

---

## Migration Safety Rules

1. **Never move a live session directory** — Claude Code sessions are bound to their exact `work_dir` path
2. **Dual-write before cutting over** — always have both old and new systems writing before removing the old
3. **Keep old files as safety net** — don't delete `.session.json` files until Phase 2 is proven stable
4. **One phase at a time** — each phase must be deployed and stable before starting the next
5. **Backup `agents.json`** — periodic copies during development (`data/agents.json.bak`)
6. **Test with live agents** — each phase must be tested with agents actually running, not just unit tests

## Estimated Phase Dependencies

```
Phase 1 (Centralized State) ─── must complete before ──→ Phase 2 (Cut Over)
Phase 2 (Cut Over)          ─── must complete before ──→ Phase 3 (Flat Layout)
Phase 2 (Cut Over)          ─── must complete before ──→ Phase 4 (Templates)
Phase 3 + 4                 ─── must complete before ──→ Phase 5 (Project Mgmt)
```

Phases 3 and 4 can run **in parallel** once Phase 2 is complete.

---

## Phase 6: Backend Abstraction

**Goal:** Extract all tmux code into `ClaudeCodeBackend`. Hub core operates through abstract `AgentBackend` interface with zero tmux references.

### Steps

- [ ] **6.1** Create `server/backends/base.py` with abstract `AgentBackend` class
  - Define `spawn()`, `terminate()`, `health_check()`, `deliver_message()`, `restart()`
  - Include type hints and docstrings for each method

- [ ] **6.2** Create `server/backends/claude_code.py` (`ClaudeCodeBackend`)
  - Move all tmux operations from `SessionManager`: `_spawn_tmux()`, `_cleanup_tmux()`, `_apply_agent_status_bar()`, `_run()`
  - Move hook installation logic
  - Move inbox file management
  - Move tmux health check (pane check)

- [ ] **6.3** Refactor `SessionManager` to use backend interface
  - `SessionManager.__init__()` takes a backend instance
  - `spawn_session()` calls `self.backend.spawn()` instead of inline tmux code
  - `_cleanup_session()` calls `self.backend.terminate()`
  - Health check loop calls `self.backend.health_check()`
  - Zero tmux imports in `session_manager.py`

- [ ] **6.4** Add `backend` field to `agents.json`
  - Each agent entry includes `"backend": "claude-code"` (default)
  - `SessionManager` selects backend based on this field
  - Future agents can use `"backend": "openclaw"` or `"backend": "generic-cli"`

- [ ] **6.5** Rename `X-ClawMux-Session` header to `ClawMux-Session`
  - Update all references in hub.py, hooks, and CLI
  - Keep backward compat: accept both headers during transition

- [ ] **6.6** Stub out `OpenClawBackend` and `GenericCLIBackend`
  - Create files with `NotImplementedError` stubs
  - Document expected configuration for each
  - No implementation yet — just the interface

### Test Checklist

- [ ] All tmux operations still work through `ClaudeCodeBackend`
- [ ] `session_manager.py` has zero `tmux` imports or references
- [ ] `grep -r "tmux" server/` only hits `server/backends/claude_code.py`
- [ ] Spawn, kill, health check, message delivery all work unchanged
- [ ] `agents.json` includes `backend` field for each agent
- [ ] `ClawMux-Session` header accepted (and `X-ClawMux-Session` still works)

### Rollback

- Inline backend code back into `SessionManager`
- Remove `server/backends/` directory
- This is a pure refactor — no behavioral changes, safe to revert

---

## Updated Phase Dependencies

```
Phase 1 (Centralized State) ─── must complete before ──→ Phase 2 (Cut Over)
Phase 2 (Cut Over)          ─── must complete before ──→ Phase 3 (Flat Layout)
Phase 2 (Cut Over)          ─── must complete before ──→ Phase 4 (Templates)
Phase 3 + 4                 ─── must complete before ──→ Phase 5 (Project Mgmt)
Phase 2 (Cut Over)          ─── must complete before ──→ Phase 6 (Backend Abstraction)
```

Phases 3, 4, and 6 can run **in parallel** once Phase 2 is complete.
