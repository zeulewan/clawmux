"""Centralized agent and project metadata store.

Manages data/agents.json — the single source of truth for agent state,
project assignments, and roles. Thread/process-safe via asyncio.Lock
with atomic file writes.

Schema:
{
    "agents": {
        "af_sky": { "session_id": "...", "project": "clawmux", ... },
        ...
    },
    "projects": {
        "clawmux": { "display_name": "ClawMux", "created_at": 1709571234.5 },
        ...
    }
}
"""

import asyncio
import json
import logging
import os
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

log = logging.getLogger("agents_store")

AGENTS_FILE = Path("data/agents.json")


@dataclass
class AgentEntry:
    session_id: str | None = None
    project: str | None = None
    role: str = "worker"          # "manager" or "worker"
    area: str = ""                # e.g. "frontend", "backend", "devops"
    backend: str = "claude-code"  # backend type
    last_active: float = 0.0
    model: str = "opus"
    state: str = "dead"           # "idle", "processing", "compacting", "dead"

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "AgentEntry":
        known = {f.name for f in cls.__dataclass_fields__.values()}
        return cls(**{k: v for k, v in data.items() if k in known})


@dataclass
class ProjectEntry:
    display_name: str = ""
    created_at: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict) -> "ProjectEntry":
        known = {f.name for f in cls.__dataclass_fields__.values()}
        return cls(**{k: v for k, v in data.items() if k in known})


class AgentsStore:
    """Read/write access to data/agents.json with atomic saves and locking."""

    def __init__(self, path: Path = AGENTS_FILE):
        self._path = path
        self._lock = asyncio.Lock()
        self._agents: dict[str, AgentEntry] = {}
        self._projects: dict[str, ProjectEntry] = {}

    # --- Load / Save ---

    async def load(self) -> None:
        """Load agents.json from disk. Creates the file if missing."""
        async with self._lock:
            self._load_sync()

    def _load_sync(self) -> None:
        if not self._path.exists():
            log.info("agents.json not found — creating empty store at %s", self._path)
            self._agents = {}
            self._projects = {}
            self._save_sync()
            return

        try:
            raw = json.loads(self._path.read_text())
            self._agents = {
                vid: AgentEntry.from_dict(data)
                for vid, data in raw.get("agents", {}).items()
            }
            self._projects = {
                slug: ProjectEntry.from_dict(data)
                for slug, data in raw.get("projects", {}).items()
            }
            log.info("Loaded %d agents, %d projects from %s",
                     len(self._agents), len(self._projects), self._path)
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            log.error("Failed to parse agents.json: %s — starting empty", e)
            self._agents = {}
            self._projects = {}

    async def save(self) -> None:
        """Atomically write agents.json (write .tmp, then os.replace)."""
        async with self._lock:
            self._save_sync()

    def _save_sync(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "agents": {vid: entry.to_dict() for vid, entry in self._agents.items()},
            "projects": {slug: entry.to_dict() for slug, entry in self._projects.items()},
        }
        tmp_path = self._path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(data, indent=2) + "\n")
        os.replace(str(tmp_path), str(self._path))

    # --- Agent CRUD ---

    async def get(self, voice_id: str) -> AgentEntry | None:
        """Get an agent entry by voice ID."""
        async with self._lock:
            entry = self._agents.get(voice_id)
            return AgentEntry.from_dict(entry.to_dict()) if entry else None

    async def set(self, voice_id: str, entry: AgentEntry) -> None:
        """Set an agent entry and persist to disk."""
        async with self._lock:
            self._agents[voice_id] = entry
            self._save_sync()

    async def update(self, voice_id: str, **kwargs) -> AgentEntry | None:
        """Update specific fields of an agent entry. Returns updated entry or None."""
        async with self._lock:
            entry = self._agents.get(voice_id)
            if not entry:
                return None
            for key, value in kwargs.items():
                if hasattr(entry, key):
                    setattr(entry, key, value)
            self._save_sync()
            return AgentEntry.from_dict(entry.to_dict())

    async def remove(self, voice_id: str) -> bool:
        """Remove an agent entry. Returns True if it existed."""
        async with self._lock:
            if voice_id in self._agents:
                del self._agents[voice_id]
                self._save_sync()
                return True
            return False

    async def all_agents(self) -> dict[str, AgentEntry]:
        """Return a copy of all agent entries."""
        async with self._lock:
            return {vid: AgentEntry.from_dict(e.to_dict()) for vid, e in self._agents.items()}

    # --- Project CRUD ---

    async def get_project(self, slug: str) -> ProjectEntry | None:
        """Get a project entry by slug."""
        async with self._lock:
            entry = self._projects.get(slug)
            return ProjectEntry.from_dict(entry.to_dict()) if entry else None

    async def set_project(self, slug: str, entry: ProjectEntry) -> None:
        """Set a project entry and persist to disk."""
        async with self._lock:
            self._projects[slug] = entry
            self._save_sync()

    async def remove_project(self, slug: str) -> bool:
        """Remove a project entry. Returns True if it existed."""
        async with self._lock:
            if slug in self._projects:
                del self._projects[slug]
                self._save_sync()
                return True
            return False

    async def all_projects(self) -> dict[str, ProjectEntry]:
        """Return a copy of all project entries."""
        async with self._lock:
            return {slug: ProjectEntry.from_dict(e.to_dict()) for slug, e in self._projects.items()}
