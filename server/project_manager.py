"""Workspace manager — single source of truth for folders, agent order, settings, and groups.

Replaces the separate projects.json, settings.json, and groups.json with a single
workspace.json. Public interface is unchanged so hub.py and session_manager.py
need no modifications.

workspace.json structure:
{
  "folders": {
    "default": {"name": "Default", "created": 1234567890, "order": 0}
  },
  "agent_order": {
    "default": ["am_adam", "af_sky", ...]   # ordered list — defines membership + position
  },
  "active_folder": "default",
  "settings": { "model": "opus", ... },
  "groups": { "my-group": {"id": "gc-xxx", "name": "my-group", "voices": [...]} }
}
"""

import json
import logging
import time
from pathlib import Path

from hub_config import DATA_DIR, LEGACY_SESSION_DIR, SESSIONS_DIR, VOICE_POOL, VOICES

log = logging.getLogger("hub.workspace")

_SETTINGS_DEFAULTS = {
    "model": "opus",
    "effort": "high",
    "auto_record": False,
    "auto_end": True,
    "auto_interrupt": False,
    "thinking_sounds": True,
    "audio_cues": True,
    "tts_enabled": True,
    "stt_enabled": True,
    "silent_startup": False,
    "quality_mode": "high",
}


class ProjectManager:
    """Manages workspace: folders, agent ordering, settings, and group chats."""

    def __init__(self) -> None:
        self._workspace_file = DATA_DIR / "workspace.json"
        self._data = self._load()

    # ── Load / Save ──────────────────────────────────────────────────────────

    def _load(self) -> dict:
        """Load workspace.json, migrating from legacy files if needed."""
        if self._workspace_file.exists():
            try:
                data = json.loads(self._workspace_file.read_text())
                data = self._ensure_defaults(data)
                return data
            except Exception as e:
                log.error("Failed to load workspace.json: %s", e)

        # Attempt migration from legacy separate files
        data = self._migrate_legacy()
        self._save_data(data)
        return data

    def _ensure_defaults(self, data: dict) -> dict:
        """Ensure required keys exist with defaults."""
        data.setdefault("folders", {})
        data.setdefault("agent_order", {})
        data.setdefault("active_folder", "default")
        data.setdefault("settings", {})
        data.setdefault("groups", {})
        # Default folder must always exist
        if "default" not in data["folders"]:
            data["folders"]["default"] = {
                "name": "Default",
                "created": time.time(),
                "order": max((f.get("order", 0) for f in data["folders"].values()), default=-1) + 1,
            }
        if "default" not in data["agent_order"]:
            data["agent_order"]["default"] = []
        return data

    def _migrate_legacy(self) -> dict:
        """Build workspace.json from legacy projects.json, settings.json, groups.json."""
        log.info("Migrating legacy data files to workspace.json")
        data: dict = {
            "folders": {},
            "agent_order": {},
            "active_folder": "default",
            "settings": {},
            "groups": {},
        }

        # Migrate projects.json
        projects_file = DATA_DIR / "projects.json"
        if projects_file.exists():
            try:
                old = json.loads(projects_file.read_text())
                data["active_folder"] = old.get("active_project", "default")
                for order_idx, (slug, proj) in enumerate(old.get("projects", {}).items()):
                    data["folders"][slug] = {
                        "name": proj.get("name", slug),
                        "created": proj.get("created", time.time()),
                        "order": order_idx,
                    }
                    data["agent_order"][slug] = proj.get("voices", [])
                log.info("Migrated projects.json: %d folders", len(data["folders"]))
            except Exception as e:
                log.error("Failed to migrate projects.json: %s", e)

        # Migrate settings.json
        settings_file = DATA_DIR / "settings.json"
        if settings_file.exists():
            try:
                data["settings"] = json.loads(settings_file.read_text())
                log.info("Migrated settings.json")
            except Exception as e:
                log.error("Failed to migrate settings.json: %s", e)

        # Migrate groups.json
        groups_file = DATA_DIR / "groups.json"
        if groups_file.exists():
            try:
                data["groups"] = json.loads(groups_file.read_text())
                log.info("Migrated groups.json: %d groups", len(data["groups"]))
            except Exception as e:
                log.error("Failed to migrate groups.json: %s", e)

        return self._ensure_defaults(data)

    def _save_data(self, data: dict | None = None) -> None:
        if data is None:
            data = self._data
        try:
            self._workspace_file.parent.mkdir(parents=True, exist_ok=True)
            self._workspace_file.write_text(json.dumps(data, indent=2))
        except Exception as e:
            log.error("Failed to save workspace.json: %s", e)

    def _save(self) -> None:
        self._save_data(self._data)

    # ── Folder properties (backwards-compat names) ────────────────────────────

    @property
    def projects(self) -> dict:
        """Return folders dict in legacy projects format for backwards compat."""
        result = {}
        for slug, folder in self._data["folders"].items():
            result[slug] = {
                "name": folder.get("name", slug),
                "created": folder.get("created", 0),
                "flat_layout": False,
                "voices": self._data["agent_order"].get(slug, []),
            }
        return result

    @property
    def active_project(self) -> str:
        return self._data.get("active_folder", "default")

    # ── Folder CRUD ───────────────────────────────────────────────────────────

    def list_projects(self) -> list[dict]:
        folders = sorted(self._data["folders"].items(), key=lambda kv: kv[1].get("order", 0))
        result = []
        for slug, folder in folders:
            result.append({
                "slug": slug,
                "name": folder.get("name", slug),
                "created": folder.get("created"),
                "flat_layout": False,
                "voices": self._data["agent_order"].get(slug, []),
                "active": slug == self.active_project,
            })
        return result

    def create_project(self, slug: str, name: str, voices: list[str] | None = None) -> dict:
        if slug in self._data["folders"]:
            raise ValueError(f"Folder '{slug}' already exists")
        if "/" in slug or ".." in slug:
            raise ValueError(f"Invalid folder slug: {slug}")
        order = max((f.get("order", 0) for f in self._data["folders"].values()), default=-1) + 1
        self._data["folders"][slug] = {"name": name, "created": time.time(), "order": order}
        self._data["agent_order"][slug] = voices or []
        self._save()
        log.info("Created folder: %s (%s) with %d agents", slug, name, len(voices or []))
        return {"slug": slug, "name": name, "voices": voices or []}

    def rename_project(self, slug: str, new_name: str, new_slug: str | None = None) -> dict:
        if slug not in self._data["folders"]:
            raise ValueError(f"Folder '{slug}' not found")
        if new_slug and new_slug != slug:
            if new_slug in self._data["folders"]:
                raise ValueError(f"Folder '{new_slug}' already exists")
            folder = self._data["folders"].pop(slug)
            folder["name"] = new_name
            self._data["folders"][new_slug] = folder
            self._data["agent_order"][new_slug] = self._data["agent_order"].pop(slug, [])
            if self._data.get("active_folder") == slug:
                self._data["active_folder"] = new_slug
            self._save()
            return {"slug": new_slug, **folder, "voices": self._data["agent_order"][new_slug]}
        self._data["folders"][slug]["name"] = new_name
        self._save()
        return {"slug": slug, **self._data["folders"][slug], "voices": self._data["agent_order"].get(slug, [])}

    def delete_project(self, slug: str) -> None:
        if slug == "default":
            raise ValueError("Cannot delete the default folder")
        if slug not in self._data["folders"]:
            raise ValueError(f"Folder '{slug}' not found")
        # Move agents to default
        agents = self._data["agent_order"].pop(slug, [])
        default_agents = self._data["agent_order"].setdefault("default", [])
        existing = set(default_agents)
        default_agents.extend(v for v in agents if v not in existing)
        del self._data["folders"][slug]
        if self.active_project == slug:
            self._data["active_folder"] = "default"
        self._save()
        log.info("Deleted folder: %s (moved %d agents to default)", slug, len(agents))

    def switch_project(self, slug: str) -> None:
        if slug not in self._data["folders"]:
            raise ValueError(f"Folder '{slug}' not found")
        self._data["active_folder"] = slug
        self._save()

    def reorder_voices(self, slug: str, voices: list[str]) -> None:
        if slug not in self._data["folders"]:
            raise ValueError(f"Folder '{slug}' not found")
        self._data["agent_order"][slug] = voices
        self._save()

    def move_voice(self, voice_id: str, new_project: str) -> None:
        if new_project not in self._data["folders"]:
            raise ValueError(f"Folder '{new_project}' not found")
        for slug, agents in self._data["agent_order"].items():
            if voice_id in agents and slug != new_project:
                agents.remove(voice_id)
        dest = self._data["agent_order"].setdefault(new_project, [])
        if voice_id not in dest:
            dest.append(voice_id)
        self._save()

    # ── Voice lookup (backwards compat) ──────────────────────────────────────

    def get_voice_folder(self, voice_id: str) -> str | None:
        """Find which folder a voice is assigned to, or None if unassigned."""
        for slug, agents in self._data["agent_order"].items():
            if voice_id in agents:
                return slug
        return None

    def get_voices(self, project_slug: str | None = None) -> list[tuple[str, str]]:
        slug = project_slug or self.active_project
        voice_ids = self._data["agent_order"].get(slug, [])
        if not voice_ids:
            return list(VOICES)
        pool_map = {v[0]: v[1] for v in VOICE_POOL}
        return [(vid, pool_map.get(vid, vid)) for vid in voice_ids]

    # ── Session directories ───────────────────────────────────────────────────

    def get_session_dir(self, voice_id: str, project_slug: str | None = None) -> Path:
        return SESSIONS_DIR / voice_id

    def get_history_prefix(self, project_slug: str | None = None) -> str | None:
        slug = project_slug or self.active_project
        if slug == "default":
            return None
        return slug if slug in self._data["folders"] else None

    # ── Settings ──────────────────────────────────────────────────────────────

    def get_settings(self) -> dict:
        result = dict(_SETTINGS_DEFAULTS)
        result.update(self._data.get("settings", {}))
        return result

    def save_settings(self, settings: dict) -> None:
        self._data["settings"] = settings
        self._save()

    # ── Groups ────────────────────────────────────────────────────────────────

    def get_groups(self) -> dict:
        return self._data.get("groups", {})

    def save_groups(self, groups: dict) -> None:
        self._data["groups"] = groups
        self._save()
