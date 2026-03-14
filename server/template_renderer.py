"""Template renderer for agent instructions.

Renders instruction templates with agent-specific variables from agents.json.
Supports multiple backends:
  - claude-code: writes CLAUDE.md + .claude/rules/role.md
  - opencode: writes INSTRUCTIONS.md + .opencode/rules/role.md, registers in opencode.json
Role-specific rules are loaded from server/templates/rules/.
"""

import json
import logging
from pathlib import Path

from agents_store import AgentsStore

log = logging.getLogger("template_renderer")

TEMPLATES_DIR = Path(__file__).parent / "templates"
TEMPLATE_FILE = TEMPLATES_DIR / "claude_md.template"
RULES_DIR = TEMPLATES_DIR / "rules"

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
        self._template = self._load_template()

    def _load_template(self) -> str:
        """Load the CLAUDE.md template file."""
        if not TEMPLATE_FILE.exists():
            log.error("Template file not found: %s", TEMPLATE_FILE)
            return ""
        return TEMPLATE_FILE.read_text()

    def reload_template(self) -> None:
        """Reload the template from disk (for dev convenience)."""
        self._template = self._load_template()

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

    async def render(self, voice_id: str) -> str | None:
        """Render CLAUDE.md for a specific agent. Returns None if agent not found."""
        entry = await self._store.get(voice_id)
        if entry is None:
            log.warning("Cannot render CLAUDE.md: agent %s not found", voice_id)
            return None

        name = voice_id_to_name(voice_id)
        role = entry.role or "worker"
        project = entry.project or ""
        repo = entry.repo or ""

        managers_section = self._build_managers_section(entry.project)

        rendered = self._template.format(
            name=name,
            role=role,
            project=project,
            area=repo,
            managers_section=managers_section,
        )

        # Clean up trailing whitespace from empty substitutions
        lines = [line.rstrip() for line in rendered.splitlines()]
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines) + "\n"

    async def render_to_file(self, voice_id: str, work_dir: Path, **_kw: str) -> bool:
        """Render instructions in ALL formats to the agent's work directory.

        Always writes both Claude Code and OpenCode formats so agents can
        switch backends without re-rendering.
        """
        content = await self.render(voice_id)
        if content is None:
            return False

        # Claude Code: CLAUDE.md
        (work_dir / "CLAUDE.md").write_text(content)
        log.info("Rendered CLAUDE.md for %s at %s", voice_id, work_dir / "CLAUDE.md")

        # OpenCode: INSTRUCTIONS.md
        (work_dir / "INSTRUCTIONS.md").write_text(content)
        log.info("Rendered INSTRUCTIONS.md for %s at %s", voice_id, work_dir / "INSTRUCTIONS.md")

        # Role rules for all backends
        await self.render_role_to_file(voice_id, work_dir)

        # Register OpenCode instruction files
        self._update_opencode_instructions(work_dir)
        return True

    async def render_role_to_file(self, voice_id: str, work_dir: Path, **_kw: str) -> bool:
        """Write role-specific rules for ALL backends."""
        entry = await self._store.get(voice_id)
        if entry is None:
            return False

        role = entry.role or ""
        claude_role = work_dir / ".claude" / "rules" / "role.md"
        opencode_role = work_dir / ".opencode" / "rules" / "role.md"

        if not role:
            for rf in (claude_role, opencode_role):
                if rf.exists():
                    rf.unlink()
                    log.info("Removed %s for %s (no role)", rf, voice_id)
            return True

        role_rules = self._load_rules(role)
        content = role_rules + "\n" if role_rules else ""
        for rf in (claude_role, opencode_role):
            rf.parent.mkdir(parents=True, exist_ok=True)
            rf.write_text(content)
        log.info("Rendered role rules (role=%s) for %s", role, voice_id)

        # Update opencode.json instructions array
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
