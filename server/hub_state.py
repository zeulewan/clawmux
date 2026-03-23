"""Shared state and helpers for the hub modules.

Holds singletons, browser state, and utility functions used by routes,
ws_handlers, monitors, and message_injection.
"""

import asyncio
import collections
import json
import logging
import logging.handlers
import re
import time
import uuid
from pathlib import Path

import hub_config
import inbox
from history_store import HistoryStore
from message_broker import MessageBroker
from project_manager import ProjectManager
from session_manager import SessionManager
from state_machine import AgentState
from agents_store import AgentsStore
from template_renderer import TemplateRenderer

# ── Logging ───────────────────────────────────────────────────────────────────

_log_file_handler = logging.handlers.RotatingFileHandler(
    "/tmp/clawmux.log", mode="a", maxBytes=10 * 1024 * 1024, backupCount=3
)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[_log_file_handler],
)
log = logging.getLogger("hub")

_NOISY_PATHS = frozenset([
    "/api/sessions", "/api/context", "/api/settings",
    "/api/projects", "/api/groupchats", "/api/debug", "/api/monitor",
])

class _NoiseFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return not any(f'"{p}' in msg or f' {p} ' in msg for p in _NOISY_PATHS)

logging.getLogger("uvicorn.access").addFilter(_NoiseFilter())


# ── Singletons ────────────────────────────────────────────────────────────────

history = HistoryStore()
project_mgr = ProjectManager()
agents_store = AgentsStore()
template_renderer = TemplateRenderer(agents_store)

from backends.claude_code import ClaudeCodeBackend
_backend = ClaudeCodeBackend()


async def _on_session_death(session_id: str):
    await send_to_browser({"type": "session_terminated", "session_id": session_id})

session_mgr = SessionManager(
    history_store=history, project_mgr=project_mgr, agents_store=agents_store,
    backend=_backend, on_session_death=_on_session_death,
)
broker = MessageBroker()


# ── Browser state ─────────────────────────────────────────────────────────────

browser_clients: set = set()          # WebSocket connections
_browser_viewed_session: str | None = None
_shutdown_mode: str = "full"

_QUEUE_MAX = 100
_QUEUE_TTL = 30
_QUEUEABLE_TYPES = {"done", "session_status", "session_ended", "structured_event", "assistant_text"}
_browser_msg_queue: collections.deque[tuple[float, dict]] = collections.deque(maxlen=_QUEUE_MAX)


async def _flush_browser_queue(ws) -> None:
    """Send all queued messages to a newly connected browser."""
    now = time.time()
    flushed = 0
    while _browser_msg_queue:
        ts, msg = _browser_msg_queue[0]
        if now - ts > _QUEUE_TTL:
            _browser_msg_queue.popleft()
            continue
        _browser_msg_queue.popleft()
        try:
            await ws.send_json(msg)
            flushed += 1
        except Exception:
            break
    if flushed:
        log.info("Flushed %d queued messages to reconnected browser", flushed)


async def send_to_browser(data: dict) -> bool:
    """Broadcast a message to all connected browser/app clients."""
    msg_type = data.get("type", "")
    session_id = data.get("session_id", "")
    if not browser_clients:
        if msg_type in _QUEUEABLE_TYPES:
            _browser_msg_queue.append((time.time(), data))
            log.info("[%s] Queued %s for browser reconnect (%d in queue)",
                     session_id, msg_type, len(_browser_msg_queue))
        return False
    dead = []
    delivered = False
    for ws in list(browser_clients):
        try:
            await ws.send_json(data)
            delivered = True
        except Exception:
            dead.append(ws)
    for ws in dead:
        browser_clients.discard(ws)
        if msg_type in ("assistant_text", "user_text", "audio"):
            log.warning("[%s] Browser client died during %s send", session_id, msg_type)
    if not delivered and dead and msg_type in _QUEUEABLE_TYPES:
        _browser_msg_queue.append((time.time(), data))
        log.info("[%s] All clients dead, queued %s for reconnect", session_id, msg_type)
    return delivered


# ── Shared helpers ────────────────────────────────────────────────────────────

def _voice_display_name(voice_id: str) -> str:
    """Convert a voice ID like 'bf_lily' to a display name like 'Lily'."""
    session = next((s for s in session_mgr.sessions.values() if s.voice == voice_id), None)
    if session and session.label:
        return session.label
    name = re.sub(r'^[a-z]{2}_', '', voice_id)
    return name.capitalize() if name else voice_id


def _resolve_slug(project_val: str) -> str:
    """Resolve a project display name or slug to the canonical slug."""
    known = project_mgr.projects
    if project_val in known:
        return project_val
    return next(
        (slug for slug, p in known.items() if p.get("name") == project_val),
        project_val,
    )


def _resolve_session(name: str):
    """Resolve a friendly name (sky, alloy) or voice ID to a session."""
    for s in session_mgr.sessions.values():
        voice_name = re.sub(r'^[a-z]{2}_', '', s.voice)
        if (voice_name == name or s.voice == name or
                s.session_id == name or s.label.lower() == name.lower()):
            return s
    return None


def _gen_msg_id() -> str:
    return "msg-" + uuid.uuid4().hex[:8]


def _hist_prefix(session) -> str | None:
    return project_mgr.get_history_prefix(session.project_slug)


def _active_model_id(session) -> str:
    return session.model_id or session.model or ""


def _session_status_msg(session, **extra) -> dict:
    return {
        "type": "session_status",
        "session_id": session.session_id,
        "state": session.state.value,
        "activity": session.activity,
        "tool_name": session.tool_name,
        "tool_input": session.tool_input,
        "backend": session.backend,
        "model_id": session.model_id,
        **extra,
    }


async def _save_activity(session, text: str) -> None:
    if not text:
        return
    session.activity_log.append(text)
    if len(session.activity_log) > 50:
        session.activity_log = session.activity_log[-50:]
    await asyncio.to_thread(history.append, session.voice, session.label, "activity", text, _hist_prefix(session))
    await send_to_browser({
        "type": "activity_text",
        "session_id": session.session_id,
        "text": text,
    })


def _load_settings() -> dict:
    settings = project_mgr.get_settings()
    settings.setdefault("tts_url", hub_config.KOKORO_URL)
    settings.setdefault("stt_url", hub_config.WHISPER_URL)
    return settings


def _save_settings(settings: dict) -> None:
    project_mgr.save_settings(settings)


# ── Shared mutable state ─────────────────────────────────────────────────────

_context_cache: dict = {}   # session_id -> usage dict
_pending_injections: dict[str, asyncio.Task] = {}
_group_chats: dict[str, dict] = {}  # keyed by group name (lowercase)


# ── Group chat helpers ────────────────────────────────────────────────────────

_voice_name_to_id: dict[str, str] = {
    name.lower(): vid for vid, name in hub_config.VOICE_POOL
}

def _resolve_voice_id(voice: str) -> str:
    if not voice:
        return voice
    pool_ids = {vid for vid, _ in hub_config.VOICE_POOL}
    if voice in pool_ids:
        return voice
    resolved = _voice_name_to_id.get(voice.lower())
    if resolved:
        return resolved
    for s in session_mgr.sessions.values():
        if s.label and s.label.lower() == voice.lower():
            return s.voice
    return voice


def _label_for_voice(voice_id: str) -> str:
    part = voice_id.split("_", 1)[-1] if "_" in voice_id else voice_id
    return part.capitalize()


def _save_groups() -> None:
    data = {
        name: {"id": g["id"], "name": g["name"], "voices": list(g["voices"])}
        for name, g in _group_chats.items()
    }
    project_mgr.save_groups(data)


def load_groups() -> None:
    try:
        data = project_mgr.get_groups()
        for name, g in data.items():
            raw_voices = g.get("voices", g.get("session_ids", []))
            normalized = [_resolve_voice_id(v) for v in raw_voices]
            _group_chats[name] = {
                "id": g["id"],
                "name": g["name"],
                "voices": normalized,
            }
        _save_groups()
    except Exception:
        pass
