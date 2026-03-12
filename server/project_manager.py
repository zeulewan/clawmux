"""Project workspace manager — multi-project support for ClawMux.

Manages project CRUD and active project switching. The "default" project
uses the legacy flat directory layout for backward compatibility.
"""

import json
import logging
import time
from pathlib import Path

from hub_config import AGENTS_PER_PROJECT, DATA_DIR, LEGACY_SESSION_DIR, SESSIONS_DIR, VOICE_POOL, VOICES

log = logging.getLogger("hub.projects")


class ProjectManager:
    def __init__(self) -> None:
        self.projects_file = DATA_DIR / "projects.json"
        self._data = self._load()

    def _load(self) -> dict:
        if self.projects_file.exists():
            try:
                data = json.loads(self.projects_file.read_text())
                # Migrate: backfill voices for projects missing the field
                changed = False
                for slug, proj in data.get("projects", {}).items():
                    if "voices" not in proj:
                        if proj.get("flat_layout"):
                            proj["voices"] = [v[0] for v in VOICES]
                        else:
                            # Named project without voices — assign from pool
                            proj["voices"] = []
                        changed = True
                # Ensure "default" project always exists
                if "default" not in data.get("projects", {}):
                    data.setdefault("projects", {})["default"] = {
                        "name": "Default",
                        "created": time.time(),
                        "flat_layout": False,
                        "voices": [],
                    }
                    changed = True
                if changed:
                    try:
                        self.projects_file.write_text(json.dumps(data, indent=2))
                        log.info("Migrated projects.json: ensured default project and assigned orphaned voices")
                    except Exception as e:
                        log.error("Failed to save migrated projects.json: %s", e)
                return data
            except Exception as e:
                log.error("Failed to load projects.json: %s", e)
        # Fresh install: create default project (empty — voices are assigned when spawned)
        return {
            "projects": {
                "default": {
                    "name": "Default",
                    "created": time.time(),
                    "flat_layout": False,
                    "voices": [],
                }
            },
            "active_project": "default",
        }

    def _save(self) -> None:
        try:
            self.projects_file.write_text(json.dumps(self._data, indent=2))
        except Exception as e:
            log.error("Failed to save projects.json: %s", e)

    @property
    def projects(self) -> dict:
        return self._data.get("projects", {})

    @property
    def active_project(self) -> str:
        return self._data.get("active_project", "default")

    def list_projects(self) -> list[dict]:
        result = []
        for slug, proj in self.projects.items():
            result.append({
                "slug": slug,
                "name": proj.get("name", slug),
                "created": proj.get("created"),
                "flat_layout": proj.get("flat_layout", False),
                "voices": proj.get("voices", []),
                "active": slug == self.active_project,
            })
        return result

    def get_voices(self, project_slug: str | None = None) -> list[tuple[str, str]]:
        """Get the list of (voice_id, display_name) for a project."""
        slug = project_slug or self.active_project
        proj = self.projects.get(slug)
        if not proj:
            return list(VOICES)

        voice_ids = proj.get("voices", [])
        if not voice_ids:
            # Legacy project without voice assignment — use defaults
            return list(VOICES)

        # Map voice_ids to (id, name) tuples from the pool
        pool_map = {v[0]: v[1] for v in VOICE_POOL}
        return [(vid, pool_map.get(vid, vid)) for vid in voice_ids]

    def _assign_voices(self) -> list[str]:
        """Assign the next available set of voices from the pool.

        Picks AGENTS_PER_PROJECT voices that aren't used by any existing project.
        If all voices are used, wraps around (reuses voices).
        """
        used = set()
        for proj in self.projects.values():
            proj_voices = proj.get("voices", [])
            if not proj_voices and proj.get("flat_layout"):
                # Legacy default project without explicit voices — use VOICES
                proj_voices = [v[0] for v in VOICES]
            for v in proj_voices:
                used.add(v)

        available = [v[0] for v in VOICE_POOL if v[0] not in used]

        if len(available) >= AGENTS_PER_PROJECT:
            selected = available[:AGENTS_PER_PROJECT]
        else:
            # Not enough unique voices — wrap around from pool start
            selected = list(available)
            pool_ids = [v[0] for v in VOICE_POOL]
            idx = 0
            while len(selected) < AGENTS_PER_PROJECT:
                selected.append(pool_ids[idx % len(pool_ids)])
                idx += 1

        # Sort alphabetically by display name for predictable default ordering
        pool_map = {v[0]: v[1] for v in VOICE_POOL}
        selected.sort(key=lambda vid: pool_map.get(vid, vid).lower())
        return selected

    def create_project(self, slug: str, name: str, voices: list[str] | None = None) -> dict:
        """Create a new project with its own subdirectory and voice assignment.

        If voices is provided, use those exact voices instead of auto-assigning.
        """
        if slug in self.projects:
            raise ValueError(f"Project '{slug}' already exists")
        if "/" in slug or ".." in slug:
            raise ValueError(f"Invalid project slug: {slug}")

        if voices is None:
            voices = self._assign_voices()

        project = {
            "name": name,
            "created": time.time(),
            "flat_layout": False,
            "voices": voices,
        }
        self._data["projects"][slug] = project
        self._save()
        log.info("Created project: %s (%s) with voices: %s", slug, name, voices)
        return {"slug": slug, **project}

    def rename_project(self, slug: str, new_name: str, new_slug: str | None = None) -> dict:
        """Rename a folder. Optionally moves to a new slug (updates all internal references)."""
        if slug not in self.projects:
            raise ValueError(f"Folder '{slug}' not found")
        if new_slug and new_slug != slug:
            if new_slug in self.projects:
                raise ValueError(f"Folder '{new_slug}' already exists")
            entry = self._data["projects"].pop(slug)
            entry["name"] = new_name
            self._data["projects"][new_slug] = entry
            if self._data.get("active_project") == slug:
                self._data["active_project"] = new_slug
            self._save()
            log.info("Renamed folder %s → %s (%s)", slug, new_slug, new_name)
            return {"slug": new_slug, **entry}
        self._data["projects"][slug]["name"] = new_name
        self._save()
        log.info("Renamed folder %s to: %s", slug, new_name)
        return {"slug": slug, **self._data["projects"][slug]}

    def delete_project(self, slug: str) -> None:
        """Remove a project from the registry. Moves its voices to default."""
        if slug == "default":
            raise ValueError("Cannot delete the default project")
        if slug not in self.projects:
            raise ValueError(f"Project '{slug}' not found")
        # Move voices to default so agents stay visible
        voices = self._data["projects"][slug].get("voices", [])
        default = self._data["projects"].setdefault("default", {
            "name": "Default", "created": time.time(), "flat_layout": False, "voices": []
        })
        existing = set(default.get("voices", []))
        default.setdefault("voices", []).extend(v for v in voices if v not in existing)
        del self._data["projects"][slug]
        if self.active_project == slug:
            self._data["active_project"] = "default"
        self._save()
        log.info("Deleted project: %s (moved %d voices to default)", slug, len(voices))

    def switch_project(self, slug: str) -> None:
        """Switch the active project. Does NOT restart or move any sessions."""
        if slug not in self.projects:
            raise ValueError(f"Project '{slug}' not found")
        self._data["active_project"] = slug
        self._save()
        log.info("Switched active project to: %s", slug)

    def reorder_voices(self, slug: str, voices: list[str]) -> None:
        """Update the voice ordering for a project."""
        if slug not in self.projects:
            raise ValueError(f"Project '{slug}' not found")
        self._data["projects"][slug]["voices"] = voices
        self._save()
        log.info("Reordered voices for project %s: %s", slug, voices)

    def get_session_dir(self, voice_id: str, project_slug: str | None = None) -> Path:
        """Get the work directory for a voice.

        All sessions use flat layout: SESSIONS_DIR/{voice_id}
        Project assignment is tracked in agents.json, not the directory path.
        """
        return SESSIONS_DIR / voice_id

    def get_history_prefix(self, project_slug: str | None = None) -> str | None:
        """Get the history subdirectory prefix for a project.

        Returns None for the default flat-layout project (uses root history dir).
        Returns the project slug for named projects.
        """
        slug = project_slug or self.active_project
        proj = self.projects.get(slug)
        if not proj or proj.get("flat_layout"):
            return None
        return slug
