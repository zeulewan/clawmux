# v0.7.3 Refactor Brief

Concise summary of the v0.7.3 architecture refactor. For full details, see the [spec](index.md) and [implementation plan](implementation.md).

## Scope

- **Flat agent directories** — replace nested project directories with flat `~/.clawmux/sessions/{voice_id}/`
- **Centralized state** — single `agents.json` replaces per-agent `.session.json` and `.project_status.json`
- **Backend abstraction** — extract all tmux code into `ClaudeCodeBackend`, hub core has zero tmux references
- **CLAUDE.md templates** — one template rendered per-agent, auto-regenerated on role/project changes
- **`~/.clawmux/` home directory** — all runtime data under `CLAWMUX_HOME` (configurable)

## Decided

- **27 agent cap** from the voice pool (expandable later)
- **Projects = logical groupings** in metadata, not filesystem. Agents move freely between projects.
- **Simplified tmux names** — just the agent name (e.g. `sky`) instead of `voice-clawmux-sky`
- **Backend interface** — abstract `AgentBackend` with `spawn()`, `terminate()`, `health_check()`, `deliver_message()`, `restart()`
- **Three planned backends** — `ClaudeCodeBackend` (tmux+hooks), `OpenClawBackend` (Gateway WebSocket), `GenericCLIBackend` (configurable CLI tools)
- **No Direct API backend** — OpenClaw handles API calls; ClawMux focuses on UI/coordination
- **Header rename** — `X-ClawMux-Session` to `ClawMux-Session` (RFC 6648)
- **Dual-write migration** — old and new systems write in parallel before cutover
- **Never move live sessions** — Claude Code sessions are bound to their working directory path

## Open / Needs Discussion

- **Group chats** — how should multi-agent conversations work? Broadcast channels? Thread-based groups? UI for creating/managing groups?
- **Agent count flexibility** — how/when to expand beyond 27? Custom voice pools? Non-voice agents?
- **Pronunciation overrides** — how to handle agent names that TTS mispronounces? Per-agent phonetic hints? Global pronunciation map?
- **New project flow UX** — exact UI for creating projects and pre-populating agents. Modal dialog? Wizard? CLI-only for now?
- **Roles system details** — what roles exist (manager, worker, researcher, ...)? What behaviors change per role? How granular are permissions?
- **Template variable scope** — what else should be injected into CLAUDE.md templates? Custom user instructions? Project-level context files?
- **Migration timeline** — how long to support legacy nested layout? Auto-migrate on next spawn or manual trigger?
