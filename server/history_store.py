"""Per-voice persistent message history stored as JSON files."""

import json
import logging
import time
from pathlib import Path

log = logging.getLogger("hub.history")

HISTORY_DIR = Path(__file__).parent / "data" / "history"
MAX_MESSAGES = 200
CLAUDE_CONTEXT_MESSAGES = 100


class HistoryStore:
    def __init__(self):
        HISTORY_DIR.mkdir(parents=True, exist_ok=True)

    def _path(self, voice_id: str) -> Path:
        safe = voice_id.replace("/", "").replace("..", "")
        return HISTORY_DIR / f"{safe}.json"

    def _load_data(self, voice_id: str) -> dict:
        path = self._path(voice_id)
        if not path.exists():
            return {}
        try:
            return json.loads(path.read_text())
        except Exception as e:
            log.error("Failed to load history for %s: %s", voice_id, e)
            return {}

    def _save_data(self, voice_id: str, data: dict) -> None:
        try:
            self._path(voice_id).write_text(json.dumps(data, indent=2))
        except Exception as e:
            log.error("Failed to save history for %s: %s", voice_id, e)

    def load(self, voice_id: str) -> list[dict]:
        return self._load_data(voice_id).get("messages", [])

    def append(self, voice_id: str, voice_name: str, role: str, text: str) -> None:
        data = self._load_data(voice_id)
        messages = data.get("messages", [])
        messages.append({"role": role, "text": text, "ts": time.time()})
        if len(messages) > MAX_MESSAGES:
            messages = messages[-MAX_MESSAGES:]
        data.update({"voice_id": voice_id, "voice_name": voice_name, "messages": messages})
        self._save_data(voice_id, data)

    def clear(self, voice_id: str) -> None:
        path = self._path(voice_id)
        if path.exists():
            path.unlink()
        log.info("Cleared history for %s", voice_id)

    def get_claude_session_id(self, voice_id: str) -> str | None:
        """Get the stored Claude session UUID for resuming."""
        return self._load_data(voice_id).get("claude_session_id")

    def set_claude_session_id(self, voice_id: str, session_id: str) -> None:
        """Store the Claude session UUID for later resume."""
        data = self._load_data(voice_id)
        data["claude_session_id"] = session_id
        self._save_data(voice_id, data)

    def save_interjections(self, voice_id: str, interjections: list[str]) -> None:
        """Persist pending interjections so they survive hub restarts."""
        data = self._load_data(voice_id)
        data["pending_interjections"] = interjections
        self._save_data(voice_id, data)

    def load_interjections(self, voice_id: str) -> list[str]:
        """Load pending interjections from previous hub run."""
        return self._load_data(voice_id).get("pending_interjections", [])

    def clear_interjections(self, voice_id: str) -> None:
        """Clear pending interjections after they've been consumed."""
        data = self._load_data(voice_id)
        if "pending_interjections" in data:
            del data["pending_interjections"]
            self._save_data(voice_id, data)
