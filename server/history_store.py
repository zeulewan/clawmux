"""Per-voice persistent message history stored as JSON files."""

import json
import logging
import time
from pathlib import Path

from hub_config import SESSIONS_DIR

log = logging.getLogger("hub.history")
MAX_MESSAGES = 2000
CLAUDE_CONTEXT_MESSAGES = 100


class HistoryStore:
    def __init__(self):
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    def _path(self, voice_id: str, project: str | None = None) -> Path:
        """Get path for a voice's history file inside its session directory."""
        safe = voice_id.replace("/", "").replace("..", "")
        agent_dir = SESSIONS_DIR / safe
        agent_dir.mkdir(parents=True, exist_ok=True)
        return agent_dir / "history.json"

    def _load_data(self, voice_id: str, project: str | None = None) -> dict:
        path = self._path(voice_id, project)
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text())
        except Exception as e:
            log.error("Failed to load history for %s: %s", voice_id, e)
            return {}

    def _save_data(self, voice_id: str, data: dict, project: str | None = None) -> None:
        try:
            self._path(voice_id, project).write_text(json.dumps(data, indent=2))
        except Exception as e:
            log.error("Failed to save history for %s: %s", voice_id, e)

    def load(self, voice_id: str, project: str | None = None) -> list[dict]:
        return self._load_data(voice_id, project).get("messages", [])

    def append(self, voice_id: str, voice_name: str, role: str, text: str, project: str | None = None, *, msg_id: str | None = None, parent_id: str | None = None, bare_ack: bool = False) -> None:
        data = self._load_data(voice_id, project)
        messages = data.get("messages", [])
        entry: dict = {"role": role, "text": text, "ts": time.time()}
        if msg_id:
            entry["id"] = msg_id
        if parent_id:
            entry["parent_id"] = parent_id
        if bare_ack:
            entry["bare_ack"] = True
        messages.append(entry)
        if len(messages) > MAX_MESSAGES:
            messages = messages[-MAX_MESSAGES:]
        data.update({"voice_id": voice_id, "voice_name": voice_name, "messages": messages})
        self._save_data(voice_id, data, project)

    def clear(self, voice_id: str, project: str | None = None) -> None:
        path = self._path(voice_id, project)
        if path.exists():
            path.unlink()
        log.info("Cleared history for %s", voice_id)

    def get_claude_session_id(self, voice_id: str, project: str | None = None) -> str | None:
        """Get the stored Claude session UUID for resuming."""
        return self._load_data(voice_id, project).get("claude_session_id")

    def set_claude_session_id(self, voice_id: str, session_id: str, project: str | None = None) -> None:
        """Store the Claude session UUID for later resume."""
        data = self._load_data(voice_id, project)
        data["claude_session_id"] = session_id
        self._save_data(voice_id, data, project)

    def save_interjections(self, voice_id: str, interjections: list[str], project: str | None = None) -> None:
        """Persist pending interjections so they survive hub restarts."""
        data = self._load_data(voice_id, project)
        data["pending_interjections"] = interjections
        self._save_data(voice_id, data, project)

    def load_interjections(self, voice_id: str, project: str | None = None) -> list[str]:
        """Load pending interjections from previous hub run."""
        return self._load_data(voice_id, project).get("pending_interjections", [])

    def clear_interjections(self, voice_id: str, project: str | None = None) -> None:
        """Clear pending interjections after they've been consumed."""
        data = self._load_data(voice_id, project)
        if "pending_interjections" in data:
            del data["pending_interjections"]
            self._save_data(voice_id, data, project)

    def copy_history(self, voice_id: str, from_project: str | None, to_project: str) -> bool:
        """Copy a voice's history from one project to another. Returns True on success.

        Strips claude_session_id and pending_interjections since those are tied
        to the source project's working directory and should not carry over.
        """
        data = self._load_data(voice_id, from_project)
        if not data:
            return False
        # Don't copy session-specific state — new project starts fresh Claude sessions
        copy = {k: v for k, v in data.items() if k not in ("claude_session_id", "pending_interjections")}
        self._save_data(voice_id, copy, to_project)
        log.info("Copied history for %s from %s to %s", voice_id, from_project or "default", to_project)
        return True
