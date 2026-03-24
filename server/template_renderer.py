"""Template renderer for agent instructions.

Per-backend templates: each backend has its own instruction template.
At spawn, the renderer picks the right template, fills variables,
and writes only the files that backend needs.

Backend → template → output files:
  - claude-code: claude-code.md → CLAUDE.md + .claude/rules/role.md
  - claude-json: claude-json.md → CLAUDE.md + .claude/rules/role.md
  - opencode: claude-code.md → INSTRUCTIONS.md + .opencode/rules/role.md
  - codex: claude-code.md → AGENTS.md
  - openclaw: claude-code.md → AGENTS.md + IDENTITY.md + SOUL.md
"""

import json
import logging
from pathlib import Path

from agents_store import AgentsStore

log = logging.getLogger("template_renderer")

TEMPLATES_DIR = Path(__file__).parent / "templates"
TEMPLATE_FILE = TEMPLATES_DIR / "claude_md.template"  # legacy fallback
RULES_DIR = TEMPLATES_DIR / "rules"

# Backend → template file mapping
_BACKEND_TEMPLATES = {
    "claude-code": TEMPLATES_DIR / "claude-code.md",
    "claude-json": TEMPLATES_DIR / "claude-json.md",
    "opencode":    TEMPLATES_DIR / "claude-code.md",  # same base, different output file
    "codex":       TEMPLATES_DIR / "claude-code.md",
    "openclaw":    TEMPLATES_DIR / "claude-code.md",
}

# Backend → which files to write
_BACKEND_OUTPUT = {
    "claude-code": {"main": "CLAUDE.md", "rules_dir": ".claude/rules"},
    "claude-json": {"main": "CLAUDE.md", "rules_dir": ".claude/rules"},
    "opencode":    {"main": "INSTRUCTIONS.md", "rules_dir": ".opencode/rules"},
    "codex":       {"main": "AGENTS.md"},
    "openclaw":    {"main": "AGENTS.md"},
}

# Voice ID to display name mapping (voice_id prefix → name)
VOICE_NAMES = {
    "af_sky": "Sky", "af_alloy": "Alloy", "af_sarah": "Sarah",
    "af_nova": "Nova", "af_bella": "Bella", "af_heart": "Heart",
    "af_jessica": "Jessica", "af_emma": "Emma",
    "am_adam": "Adam", "am_echo": "Echo", "am_onyx": "Onyx",
    "am_fenrir": "Fenrir", "am_liam": "Liam", "am_michael": "Michael",
    "bm_fable": "Fable", "bm_george": "George", "bm_daniel": "Daniel",
}


def voice_id_to_name(voice_id: str) -> str:
    """Convert a voice_id like 'af_sky' to display name 'Sky'."""
    if voice_id in VOICE_NAMES:
        return VOICE_NAMES[voice_id]
    # Fallback: strip prefix and capitalize
    parts = voice_id.split("_", 1)
    return parts[-1].capitalize() if parts else voice_id


class TemplateRenderer:
    """Renders CLAUDE.md files from a template and agents.json data."""

    def __init__(self, agents_store: AgentsStore):
        self._store = agents_store
        self._templates: dict[str, str] = {}
        self._load_templates()

    def _load_templates(self) -> None:
        """Load all per-backend templates."""
        for backend, path in _BACKEND_TEMPLATES.items():
            if path.exists():
                self._templates[backend] = path.read_text()
        # Legacy fallback
        if TEMPLATE_FILE.exists():
            self._templates.setdefault("claude-code", TEMPLATE_FILE.read_text())

    def reload_template(self) -> None:
        """Reload all templates from disk."""
        self._load_templates()

    def _load_rules(self, role: str) -> str:
        """Load role-specific rules from templates/rules/{role}.md."""
        rules_file = RULES_DIR / f"{role.lower()}.md"
        if rules_file.exists():
            return rules_file.read_text().strip()
        return ""

    def _build_managers_section(self, project: str | None) -> str:
        """Build the managers section listing project managers."""
        if not project:
            return "No project assigned."

        # Find managers in the same project
        managers = []
        for vid, entry in self._store._agents.items():
            if entry.project == project and entry.role.lower() == "manager":
                name = voice_id_to_name(vid)
                managers.append((name, vid))

        if not managers:
            return "No managers assigned to this project."

        lines = []
        for i, (name, vid) in enumerate(sorted(managers)):
            label = "Primary" if i == 0 else "Secondary"
            lines.append(f"- **Manager {i + 1} ({label}):** {name}")

        return "\n".join(lines)

    async def render(self, voice_id: str, backend: str = "claude-code") -> str | None:
        """Render instructions for a specific agent + backend."""
        entry = await self._store.get(voice_id)
        if entry is None:
            log.warning("Cannot render instructions: agent %s not found", voice_id)
            return None

        template = self._templates.get(backend, self._templates.get("claude-code", ""))
        if not template:
            log.error("No template for backend %s", backend)
            return None

        name = voice_id_to_name(voice_id)
        role = entry.role or "worker"
        project = entry.project or ""
        managers_section = self._build_managers_section(entry.project)

        rendered = template.format(
            name=name,
            role=role,
            project=project,
            area=entry.repo or "",
            managers_section=managers_section,
        )

        lines = [line.rstrip() for line in rendered.splitlines()]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines) + "\n"

    async def render_to_file(self, voice_id: str, work_dir: Path,
                             backend: str = "claude-code", **_kw: str) -> bool:
        """Render instructions for one backend to the agent's work directory.

        Each agent gets only the files their backend needs.
        """
        content = await self.render(voice_id, backend)
        if content is None:
            return False

        output = _BACKEND_OUTPUT.get(backend, _BACKEND_OUTPUT["claude-code"])
        main_file = output["main"]

        # For codex/openclaw: append role rules inline (no separate rules dir)
        if backend in ("codex", "openclaw"):
            entry = await self._store.get(voice_id)
            role = entry.role if entry else ""
            role_rules = self._load_rules(role) if role else ""
            if role_rules:
                content += "\n" + role_rules + "\n"

        # Write main instruction file
        (work_dir / main_file).write_text(content)

        # Write role rules to separate dir (Claude Code, Claude JSON, OpenCode)
        rules_dir = output.get("rules_dir")
        if rules_dir:
            await self.render_role_to_file(voice_id, work_dir)

        # OpenClaw extras
        if backend == "openclaw":
            name = voice_id_to_name(voice_id)
            entry = await self._store.get(voice_id)
            role = entry.role if entry else ""
            self._write_openclaw_identity(work_dir, name, voice_id)
            self._write_openclaw_soul(work_dir, name, role)

        log.info("Rendered %s for %s (backend=%s)", main_file, voice_id, backend)
        return True

    async def render_role_to_file(self, voice_id: str, work_dir: Path, **_kw: str) -> bool:
        """Write role-specific rules for ALL backends."""
        entry = await self._store.get(voice_id)
        if entry is None:
            return False

        role = entry.role or ""
        claude_role = work_dir / ".claude" / "rules" / "role.md"
        opencode_role = work_dir / ".opencode" / "rules" / "role.md"

        name = voice_id_to_name(voice_id)

        if not role:
            for rf in (claude_role, opencode_role):
                if rf.exists():
                    rf.unlink()
                    log.info("Removed %s for %s (no role)", rf, voice_id)
            # Codex + OpenClaw: re-render AGENTS.md without role rules
            agents_md = work_dir / "AGENTS.md"
            if agents_md.exists():
                base_content = await self.render(voice_id)
                if base_content:
                    agents_md.write_text(base_content)
            # OpenClaw: update SOUL.md (role removed)
            self._write_openclaw_soul(work_dir, name, "")
            self._update_opencode_instructions(work_dir)
            return True

        role_rules = self._load_rules(role)
        content = role_rules + "\n" if role_rules else ""
        for rf in (claude_role, opencode_role):
            rf.parent.mkdir(parents=True, exist_ok=True)
            rf.write_text(content)
        log.info("Rendered role rules (role=%s) for %s", role, voice_id)

        # Codex + OpenClaw: re-render AGENTS.md with updated role rules appended inline
        agents_md = work_dir / "AGENTS.md"
        if agents_md.exists():
            base_content = await self.render(voice_id)
            if base_content:
                agents_content = base_content
                if content:
                    agents_content += "\n" + content
                agents_md.write_text(agents_content)

        # OpenClaw: update SOUL.md (role changed)
        self._write_openclaw_soul(work_dir, name, role)
        # Update opencode.json instructions array (needed for standalone role changes)
        self._update_opencode_instructions(work_dir)
        return True

    async def render_all(self, sessions: dict | None = None) -> int:
        """Regenerate instructions (all formats) for all agents with known work directories.

        Args:
            sessions: dict of session_id -> session objects with .voice and .work_dir.
                      If None, renders without writing (dry run).

        Returns:
            Number of agents rendered.
        """
        if sessions is None:
            log.info("render_all called without sessions — no files written")
            return 0

        count = 0
        for session in sessions.values():
            voice_id = getattr(session, "voice", None)
            work_dir = getattr(session, "work_dir", None)
            if voice_id and work_dir:
                if await self.render_to_file(voice_id, Path(work_dir)):
                    count += 1

        log.info("Rendered %d instruction sets", count)
        return count

    def _write_openclaw_identity(self, work_dir: Path, name: str, voice_id: str) -> None:
        """Write IDENTITY.md for OpenClaw — agent name and voice."""
        identity = f"# Identity\n\nName: {name}\nVoice: {voice_id}\n"
        (work_dir / "IDENTITY.md").write_text(identity)

    def _write_openclaw_soul(self, work_dir: Path, name: str, role: str) -> None:
        """Write SOUL.md for OpenClaw — minimal persona description."""
        soul = (
            f"# Soul\n\n"
            f"{name} is a ClawMux agent"
            f"{f' in the {role} role' if role else ''}.\n"
            f"Communicate via `clawmux send`. Follow instructions in AGENTS.md.\n"
        )
        (work_dir / "SOUL.md").write_text(soul)

    def _update_opencode_instructions(self, work_dir: Path) -> None:
        """Merge instruction file paths into opencode.json."""
        config_path = work_dir / "opencode.json"
        config: dict = {}
        if config_path.exists():
            try:
                config = json.loads(config_path.read_text())
            except Exception:
                pass

        # Collect instruction files that exist
        instruction_paths = []
        if (work_dir / "INSTRUCTIONS.md").exists():
            instruction_paths.append("INSTRUCTIONS.md")
        role_file = work_dir / ".opencode" / "rules" / "role.md"
        if role_file.exists():
            instruction_paths.append(".opencode/rules/role.md")

        config["instructions"] = instruction_paths

        try:
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            log.info("Updated opencode.json instructions: %s", instruction_paths)
        except Exception as e:
            log.error("Failed to update opencode.json: %s", e)
