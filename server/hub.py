"""ClawMux — session launcher, TTS/STT engine, and WebSocket multiplexer.

Standalone FastAPI service that:
  - Spawns Claude Code sessions in tmux
  - Handles TTS (Kokoro) and STT (Whisper) for all sessions
  - Multiplexes audio between browser and sessions via a single browser WS

Usage:
    python hub.py
"""

import asyncio
import base64
import collections
import json
import logging
import logging.handlers
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse

from history_store import HistoryStore
import hub_config
from hub_config import HUB_PORT, HUB_START_TIME
import inbox
from message_broker import MessageBroker
from project_manager import ProjectManager
from session_manager import SessionManager
from state_machine import AgentState

from agents_store import AgentsStore
from template_renderer import TemplateRenderer

# Logging
_log_file_handler = logging.handlers.RotatingFileHandler(
    "/tmp/clawmux.log", mode="a", maxBytes=10 * 1024 * 1024, backupCount=3
)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stderr),
        _log_file_handler,
    ],
)
log = logging.getLogger("hub")

# Filter noisy polling endpoints from uvicorn access log
_NOISY_PATHS = frozenset([
    "/api/sessions", "/api/context", "/api/settings",
    "/api/projects", "/api/groupchats", "/api/debug",
])

class _NoiseFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        return not any(f'"{p}' in msg or f' {p} ' in msg for p in _NOISY_PATHS)

logging.getLogger("uvicorn.access").addFilter(_NoiseFilter())

history = HistoryStore()
project_mgr = ProjectManager()
agents_store = AgentsStore()
template_renderer = TemplateRenderer(agents_store)
from backends.claude_code import ClaudeCodeBackend
_backend = ClaudeCodeBackend()
async def _on_session_death(session_id: str):
    await send_to_browser({"type": "session_terminated", "session_id": session_id})

session_mgr = SessionManager(history_store=history, project_mgr=project_mgr, agents_store=agents_store, backend=_backend, on_session_death=_on_session_death)
broker = MessageBroker()

def _resolve_slug(project_val: str) -> str:
    """Resolve a project display name or slug to the canonical slug."""
    known = project_mgr.projects
    if project_val in known:
        return project_val
    return next(
        (slug for slug, p in known.items() if p.get("name") == project_val),
        project_val,
    )

# Named group chats: name -> {id, name, session_ids, created_at}
# Independent of individual sessions — agents can still be messaged directly.
_group_chats: dict[str, dict] = {}  # keyed by group name (lowercase)

# Per-session pending tmux injection tasks (keyed by session_id)
_pending_injections: dict[str, asyncio.Task] = {}
# Per-session delivery locks — serializes concurrent injections so Enter never fires mid-paste
_injection_locks: dict[str, asyncio.Lock] = {}


def _hist_prefix(session) -> str | None:
    """Get the history prefix for a session's project."""
    return project_mgr.get_history_prefix(session.project_slug)


def _gen_msg_id() -> str:
    """Generate a short unique message ID for history tracking."""
    return "msg-" + uuid.uuid4().hex[:8]


async def _save_activity(session, text: str) -> None:
    """Save a completed activity entry in history and broadcast to browser.

    Called at the END of a state/activity — logs what just finished:
    - Wait WS disconnect → logs 'Waiting' (agent was waiting, now processing)
    - PostToolUse → logs the tool name (tool just completed)
    """
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

# Browser WebSocket clients (multiple connections supported)
browser_clients: set[WebSocket] = set()

# Currently viewed session (browser tells us which tab is active)
_browser_viewed_session: str | None = None

# Shutdown mode: "full" kills sessions, "reload" keeps them alive
_shutdown_mode: str = "full"

# Message queue for when browser is disconnected (bounded, with timestamps for TTL)
_QUEUE_MAX = 100
_QUEUE_TTL = 30  # seconds — discard queued messages older than this
_QUEUEABLE_TYPES = {"done", "session_status", "session_ended"}
# assistant_text, user_text, agent_message, user_ack are NOT queued — they are persisted
# in history and recovered via cursor-based sync (_reconnectSyncSession) on reconnect.
# Queuing them caused duplication: queue replay + history sync both added the same message.
_browser_msg_queue: collections.deque[tuple[float, dict]] = collections.deque(maxlen=_QUEUE_MAX)


async def _flush_browser_queue(ws: WebSocket) -> None:
    """Send all queued messages to a newly connected browser, discarding stale ones."""
    now = time.time()
    flushed = 0
    while _browser_msg_queue:
        ts, msg = _browser_msg_queue[0]
        if now - ts > _QUEUE_TTL:
            _browser_msg_queue.popleft()  # too old, discard
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
    """Broadcast a message to all connected browser/app clients.
    Returns True if at least one client received the message."""
    msg_type = data.get("type", "")
    session_id = data.get("session_id", "")
    if not browser_clients:
        # Queue important messages for replay when browser reconnects
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
    # If all clients failed, queue for replay on reconnect
    if not delivered and dead and msg_type in _QUEUEABLE_TYPES:
        _browser_msg_queue.append((time.time(), data))
        log.info("[%s] All clients dead, queued %s for reconnect", session_id, msg_type)
    return delivered


async def heartbeat_loop() -> None:
    """Ping all browser clients every 30s, remove dead connections."""
    while True:
        await asyncio.sleep(30)
        dead = []
        for ws in list(browser_clients):
            try:
                await ws.send_json({"type": "ping"})
            except Exception:
                dead.append(ws)
        for ws in dead:
            log.info("Heartbeat: removing dead client (%d remain)", len(browser_clients) - 1)
            browser_clients.discard(ws)



async def stuck_buffer_monitor_loop() -> None:
    """Detect and auto-fix agents with text stuck in their tmux input buffer.

    '[Pasted text' appears in the pane when send-keys -l delivered text but
    Enter was never sent. Poll every 10s; if the pattern persists for two
    consecutive checks (confirming it's not mid-injection), send Enter and log.
    """
    _stuck_seen: dict[str, int] = {}  # session_id -> consecutive-stuck-count
    while True:
        await asyncio.sleep(10)
        for session_id in list(session_mgr.sessions):
            session = session_mgr.sessions.get(session_id)
            if not session or session.state == AgentState.DEAD or not session.work_dir:
                _stuck_seen.pop(session_id, None)
                continue
            try:
                result = await asyncio.create_subprocess_exec(
                    "tmux", "capture-pane", "-t", session.tmux_session, "-p",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                stdout, _ = await result.communicate()
                pane = stdout.decode(errors="replace") if stdout else ""
            except Exception:
                continue
            # Check last 10 lines for stuck input — two patterns:
            # 1. Long messages: Claude Code compresses as "[Pasted text #N +M lines]"
            # 2. Short/medium messages: shows as "❯ <content>" with content after the prompt
            #    Multi-line pastes can span several lines above the status bar.
            last_lines = pane.strip().splitlines()[-10:]
            snippet = "\n".join(last_lines)
            is_stuck = (
                "[Pasted text" in snippet
                or "[Typed text" in snippet
                or any(line.startswith('❯') and len(line.rstrip()) > 1 for line in last_lines)
            )
            if is_stuck:
                count = _stuck_seen.get(session_id, 0) + 1
                _stuck_seen[session_id] = count
                if count >= 2:
                    # Confirmed stuck (not mid-injection) — auto-fix and log
                    log.warning("[%s] STUCK BUFFER detected (seen %dx) — sending Enter to unblock", session_id, count)
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            "tmux", "send-keys", "-t", session.tmux_session, "Enter",
                            stdout=asyncio.subprocess.DEVNULL,
                            stderr=asyncio.subprocess.DEVNULL,
                        )
                        await proc.communicate()
                        _stuck_seen[session_id] = 0
                        log.info("[%s] Stuck buffer cleared", session_id)
                    except Exception as exc:
                        log.error("[%s] Failed to clear stuck buffer: %s", session_id, exc)
            else:
                _stuck_seen.pop(session_id, None)


async def compaction_monitor_loop() -> None:
    """Poll tmux panes for compaction status when context usage is high (>=80%)."""
    while True:
        await asyncio.sleep(3)
        for session_id in list(session_mgr.sessions):
            session = session_mgr.sessions.get(session_id)
            if not session or session.state == AgentState.DEAD:
                continue
            # Check when context usage is >= 80% OR when already compacting
            usage = _context_cache.get(session_id)
            if (not usage or usage["percent"] < 80) and session.state != AgentState.COMPACTING:
                continue
            # Capture tmux pane and check for compaction text
            try:
                result = await asyncio.create_subprocess_exec(
                    "tmux", "capture-pane", "-t", session.tmux_session, "-p",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await result.communicate()
                pane_text = stdout.decode(errors="replace") if stdout else ""
            except Exception as exc:
                log.debug("[%s] compaction tmux capture failed: %s", session_id, exc)
                continue
            # Check for active compaction by scanning lines bottom-up
            lines = pane_text.strip().splitlines()
            is_compacting = False
            for line in reversed(lines):
                ll = line.lower().strip()
                if "compacting" in ll and "compacted" not in ll:
                    is_compacting = True
                    break
                if "compacted" in ll:
                    # Most recent compaction-related line says "compacted" (done)
                    break
            was_compacting = session.state == AgentState.COMPACTING
            if is_compacting != was_compacting:
                if is_compacting:
                    session.set_state(AgentState.COMPACTING)
                else:
                    session.set_state(AgentState.PROCESSING)
                await send_to_browser({
                    "type": "compaction_status",
                    "session_id": session_id,
                    "compacting": is_compacting,
                })
                log.info("[%s] Compaction %s", session_id, "started" if is_compacting else "finished")


# --- TTS / STT (extracted to voice.py) ---
from voice import router as voice_router, tts, tts_captioned, stt, strip_non_speakable, reload_pronunciation_overrides
import voice


# --- Context usage cache ---
_context_cache: dict = {}  # session_id -> {total_context_tokens, output_tokens, context_limit, percent}

async def context_poll_loop() -> None:
    """Poll context usage for all sessions every 30s, cache results."""
    while True:
        for sid in list(session_mgr.sessions):
            session = session_mgr.sessions.get(sid)
            if not session or session.state == AgentState.DEAD:
                continue
            try:
                usage = await asyncio.to_thread(session_mgr.get_context_usage, sid)
                if usage:
                    _context_cache[sid] = usage
            except Exception:
                pass
        await asyncio.sleep(30)


# --- Usage poller (replaces per-session statusline polling) ---
_USAGE_POLL_INTERVAL = 1800  # 30 minutes
_USAGE_CACHE_PATH = Path.home() / ".claude" / "usage-cache.json"
_CREDENTIALS_PATH = Path.home() / ".claude" / ".credentials.json"
_USAGE_API_URL = "https://api.anthropic.com/api/oauth/usage"

async def _fetch_usage_from_api() -> dict | None:
    """Fetch usage stats from Anthropic OAuth endpoint."""
    if not _CREDENTIALS_PATH.exists():
        log.debug("No credentials file for usage polling")
        return None
    try:
        creds = json.loads(_CREDENTIALS_PATH.read_text())
        token = creds.get("claudeAiOauth", {}).get("accessToken")
        if not token:
            return None
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                _USAGE_API_URL,
                headers={
                    "Authorization": f"Bearer {token}",
                    "anthropic-beta": "oauth-2025-04-20",
                },
            )
            if resp.status_code == 429:
                log.warning("Usage API rate limited, keeping last good data")
                return None
            resp.raise_for_status()
            data = resp.json()
            if "five_hour" not in data or "error" in data:
                log.warning("Usage API returned unexpected data: %s", list(data.keys()))
                return None
            return data
    except Exception as e:
        log.warning("Usage poll failed: %s", e)
        return None

async def usage_poll_loop() -> None:
    """Poll Anthropic usage API every 30 minutes, update cache + sidecar."""
    global _last_good_usage
    await asyncio.sleep(30)  # initial delay to let hub finish starting
    backoff = _USAGE_POLL_INTERVAL
    while True:
        data = await _fetch_usage_from_api()
        if data:
            _last_good_usage = data
            try:
                _USAGE_CACHE_PATH.write_text(json.dumps(data, indent=2))
            except Exception:
                pass
            _save_usage_sidecar(data)
            log.info("Usage cache refreshed (5h: %.0f%%, 7d: %.0f%%)",
                     data.get("five_hour", {}).get("utilization", 0),
                     data.get("seven_day", {}).get("utilization", 0))
            backoff = _USAGE_POLL_INTERVAL
        else:
            # Back off on failure (rate limit or error) up to 2× poll interval
            backoff = min(backoff * 2, _USAGE_POLL_INTERVAL * 2)
            log.warning("Usage poll failed/rate-limited, backing off to %ds", backoff)
        await asyncio.sleep(backoff)


# --- FastAPI app ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Hub starting on port %d", HUB_PORT)
    # Restore saved settings
    saved = _load_settings()
    import hub_config
    hub_config.CLAUDE_MODEL = saved.get("model", "opus")
    hub_config.CLAUDE_EFFORT = saved.get("effort", "high")
    if saved.get("tts_url"):
        hub_config.KOKORO_URL = saved["tts_url"].rstrip("/")
    if saved.get("stt_url"):
        hub_config.WHISPER_URL = saved["stt_url"].rstrip("/")
    if saved.get("quality_mode") in ("high", "medium", "low"):
        hub_config.QUALITY_MODE = saved["quality_mode"]
    log.info("Model: %s, TTS: %s, STT: %s",
             hub_config.CLAUDE_MODEL,
             hub_config.KOKORO_URL, hub_config.WHISPER_URL)
    voice.reload_pronunciation_overrides()
    await agents_store.load()
    _load_groups()
    await session_mgr.cleanup_stale_sessions()
    # Send Enter to every adopted session to clear any text that was left in the tmux
    # input buffer by an injection that was killed mid-way during the previous hub run.
    # On a clean Claude Code prompt, Enter is a no-op. On a stuck buffer, it submits it.
    for session in list(session_mgr.sessions.values()):
        if session.tmux_session:
            try:
                proc = await asyncio.create_subprocess_exec(
                    "tmux", "send-keys", "-t", session.tmux_session, "Enter",
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.DEVNULL,
                )
                await proc.communicate()
            except Exception as _e:
                log.debug("[%s] Startup Enter failed: %s", session.session_id, _e)
    # Flush any pending interjections (saved across hub restarts) into inbox for delivery.
    # The agent is assumed idle after a hub restart, so we convert interjections to inbox
    # messages and trigger immediate injection rather than waiting for a new voice message.
    for session in list(session_mgr.sessions.values()):
        if session.interjections and session.work_dir:
            combined = " ... ".join(session.interjections)
            session.interjections.clear()
            await asyncio.to_thread(history.clear_interjections,
                                    session.voice, _hist_prefix(session))
            import uuid as _uuid
            await asyncio.to_thread(inbox.write, session.work_dir, {
                "id": f"msg-{_uuid.uuid4().hex[:8]}",
                "from": "user",
                "type": "voice",
                "content": combined,
            })
            session.set_state(AgentState.IDLE)
            log.info("[%s] Flushed %d interjection(s) to inbox on startup", session.session_id, 1)
    broker.start()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    hb_task = asyncio.create_task(heartbeat_loop())
    compaction_task = asyncio.create_task(compaction_monitor_loop())
    stuck_task = asyncio.create_task(stuck_buffer_monitor_loop())
    context_task = asyncio.create_task(context_poll_loop())
    usage_task = asyncio.create_task(usage_poll_loop())
    # Load saved Whisper model quality on startup
    startup_model = hub_config.QUALITY_MODEL_MAP.get(hub_config.QUALITY_MODE)
    if startup_model:
        asyncio.create_task(_load_whisper_model(startup_model))
    try:
        yield
    finally:
        broker.stop()
        timeout_task.cancel()
        hb_task.cancel()
        compaction_task.cancel()
        context_task.cancel()
        usage_task.cancel()
        if _shutdown_mode == "reload":
            log.info("Hub reloading — keeping tmux sessions alive for re-adoption")
            # Save any pending interjections before shutdown
            for sid, session in session_mgr.sessions.items():
                if session.interjections:
                    history.save_interjections(session.voice, session.interjections, _hist_prefix(session))
        else:
            log.info("Hub shutting down, terminating all sessions")
            for sid in list(session_mgr.sessions):
                try:
                    await session_mgr.terminate_session(sid)
                except Exception:
                    pass


app = FastAPI(lifespan=lifespan)
app.include_router(voice_router)
STATIC_DIR = Path(__file__).parent.parent / "static"
_SHARED_UPLOADS_DIR = hub_config.DATA_DIR / "uploads"


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "hub.html", headers={
        "Cache-Control": "no-cache, no-store, must-revalidate",
        "Pragma": "no-cache",
        "Expires": "0",
    })


@app.get("/static/{filename:path}")
async def static_file(filename: str):
    path = STATIC_DIR / filename
    if path.is_file():
        return FileResponse(path, headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
        })
    return JSONResponse({"error": "not found"}, status_code=404)


@app.get("/uploads/{filename:path}")
async def serve_upload(filename: str):
    """Serve agent-posted images from the shared uploads directory."""
    path = (_SHARED_UPLOADS_DIR / filename).resolve()
    if not str(path).startswith(str(_SHARED_UPLOADS_DIR.resolve())):
        return JSONResponse({"error": "forbidden"}, status_code=403)
    if not path.is_file():
        return JSONResponse({"error": "not found"}, status_code=404)
    return FileResponse(path)


# --- Browser WebSocket ---

@app.websocket("/ws")
async def browser_websocket(ws: WebSocket):
    await ws.accept()
    browser_clients.add(ws)
    log.info("Client connected (%d total)", len(browser_clients))

    try:
        # Send current session list
        await ws.send_json({
            "type": "session_list",
            "sessions": session_mgr.list_sessions(),
        })

        # Flush any messages queued while browser was disconnected
        await _flush_browser_queue(ws)

        while True:
            data = await ws.receive_json()
            await handle_browser_message(data)
    except WebSocketDisconnect:
        log.info("Client disconnected")
    except Exception as e:
        log.error("Client WS error: %s: %s", type(e).__name__, e)
    finally:
        browser_clients.discard(ws)
        log.info("Clients remaining: %d", len(browser_clients))
        if not browser_clients:
            # No clients left — unblock any waiting playback events
            for session in session_mgr.sessions.values():
                if session.playback_done:
                    session.playback_done.set()


async def handle_browser_message(data: dict) -> None:
    """Route browser messages to the correct session's bridge state."""
    session_id = data.get("session_id")
    msg_type = data.get("type")

    if not session_id:
        log.warning("Browser message without session_id: %s", msg_type)
        return

    session = session_mgr.sessions.get(session_id)
    if not session:
        log.warning("Browser message for unknown session: %s", session_id)
        return

    session.touch()

    if msg_type == "playback_done":
        log.info("[%s] playback_done from browser", session_id)
        session.playback_done.set()

    elif msg_type == "audio":
        payload = data.get("data", "")
        if not payload:
            # Empty audio (e.g. cancel recording) — skip transcription
            log.info("[%s] Empty audio from browser, skipping", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
            return
        audio_bytes = base64.b64decode(payload)
        log.info("[%s] Audio from browser: %d bytes", session_id, len(audio_bytes))
        # Check if STT is disabled
        if not _load_settings().get("stt_enabled", True):
            log.info("[%s] STT disabled, skipping transcription", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
            return
        # Transcribe and deliver via inbox (CLI mode — no converse loop)
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
        text = await stt(audio_bytes)
        if text:
            log.info("[%s] Audio STT: %s", session_id, text[:100])
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)
            if session.work_dir:
                await _inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": text,
                })
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
        else:
            log.info("[%s] Audio STT: empty result", session_id)
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "text":
        text = data.get("text", "").strip()
        if text:
            log.info("[%s] Text from browser: %s", session_id, text[:100])
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)
            if session.work_dir:
                await _inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "text",
                    "content": text,
                })
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "interjection":
        # User spoke/typed while agent was busy — transcribe and queue
        payload = data.get("data", "")
        text = data.get("text", "").strip()
        if text:
            # Text interjection
            log.info("[%s] Text interjection: %s", session_id, text[:100])
        elif payload:
            # Audio interjection — transcribe now
            audio_bytes = base64.b64decode(payload)
            log.info("[%s] Audio interjection: %d bytes, transcribing...", session_id, len(audio_bytes))
            if not _load_settings().get("stt_enabled", True):
                log.info("[%s] STT disabled, skipping interjection transcription", session_id)
                return
            await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
            text = await stt(audio_bytes)
            log.info("[%s] Interjection STT: %s", session_id, text[:100] if text else "(empty)")
        if text:
            session.interjections.append(text)
            umid = _gen_msg_id()
            # Send to browser FIRST for instant display, then persist
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "interjection": True, "msg_id": umid})
            await asyncio.to_thread(history.save_interjections, session.voice, session.interjections, _hist_prefix(session))
            await asyncio.to_thread(history.append, session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)

            # If agent is in wait mode, push via inbox for immediate pickup by wait WS
            if session.state == AgentState.IDLE and session.work_dir:
                log.info("[%s] Agent in wait, pushing voice message via inbox", session_id)
                combined = " ... ".join(session.interjections)
                session.interjections.clear()
                await asyncio.to_thread(history.clear_interjections, session.voice, _hist_prefix(session))
                await _inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": combined,
                })
            elif session.work_dir:
                # Agent not in wait — write to inbox for hook-based delivery
                # (PostToolUse/PreToolUse will pick it up via additionalContext)
                await _inbox_write_and_notify(session, {
                    "id": umid,
                    "from": "user",
                    "type": "voice",
                    "content": text,
                })
                log.info("[%s] Voice interjection written to inbox for hook delivery", session_id)
                # Signal browser that message was queued (not actively processing)
                await send_to_browser({"session_id": session_id, "type": "done", "processing": False})

    elif msg_type == "set_mode":
        mode = data.get("mode", "voice")
        session.text_mode = (mode == "text")
        log.info("[%s] Mode set to %s", session_id, mode)

    elif msg_type == "set_model":
        model = data.get("model", "")
        if model in ("opus", "sonnet", "haiku", ""):
            session.model = model
            log.info("[%s] Model set to %s", session_id, model or "(global default)")

    elif msg_type == "restart_model":
        # User confirmed model restart from UI
        model = data.get("model", "")
        if model in ("opus", "sonnet", "haiku", ""):
            session.model = model
            log.info("[%s] Model restart requested: %s", session_id, model)
            asyncio.create_task(session_mgr.restart_claude_with_model(session_id))

    elif msg_type == "restart_effort":
        # User changed effort level — requires restart
        effort = data.get("effort", "")
        if effort in ("low", "medium", "high"):
            session.effort = effort
            log.info("[%s] Effort restart requested: %s", session_id, effort)
            asyncio.create_task(session_mgr.restart_claude_with_model(session_id))

    elif msg_type == "user_ack":
        # User acknowledged a message (double-click or thumbs-up button)
        msg_id = data.get("msg_id", "")
        if msg_id:
            ack_id = _gen_msg_id()
            log.info("[%s] User ack on %s", session_id, msg_id)
            # Save to history so acks persist across reloads
            await asyncio.to_thread(history.append, session.voice, session.label, "user", "",
                           _hist_prefix(session), msg_id=ack_id,
                           parent_id=msg_id, bare_ack=True)
            await send_to_browser({
                "session_id": session_id,
                "type": "user_ack",
                "msg_id": msg_id,
                "ack_id": ack_id,
            })
            # Deliver ack to agent inbox so it gets notified
            if session.work_dir:
                await _inbox_write_and_notify(session, {
                    "from": "user",
                    "type": "ack",
                    "content": "",
                    "parent_id": msg_id,
                })


# --- Wait WebSocket (push-based inbox delivery for CLI) ---

@app.websocket("/ws/wait/{session_id}")
async def wait_websocket(ws: WebSocket, session_id: str):
    """Push-based inbox delivery. CLI connects, blocks until a message arrives."""
    await ws.accept()
    session = session_mgr.sessions.get(session_id)
    if not session:
        await ws.close(code=4004, reason="Session not found")
        return

    log.info("[%s] Wait WS connected", session_id)
    session.activity = ""
    session.tool_name = ""
    session.tool_input = {}
    session.set_state(AgentState.IDLE)
    await _save_activity(session, "Idle")

    # Tell browser agent is idle (so voice input isn't treated as interjection)
    await send_to_browser({"session_id": session_id, "type": "listening", "state": "idle"})
    await send_to_browser({
        "type": "session_status",
        "session_id": session_id,
        "state": session.state.value,
        "activity": session.activity,
        "tool_name": session.tool_name,
        "tool_input": session.tool_input,
    })

    # Register this WS for push notifications
    if not hasattr(session, "_wait_queue"):
        session._wait_queue = asyncio.Queue()

    try:
        # First, check if there are already pending inbox messages
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                await ws.send_json({"type": "messages", "messages": messages})
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session_id,
                    "count": 0,
                })
                return

        # Block until a message is pushed to our queue
        while True:
            try:
                msg = await asyncio.wait_for(session._wait_queue.get(), timeout=5)
                # Clear inbox file to prevent duplicate delivery on next wait
                if session.work_dir:
                    await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
                await ws.send_json({"type": "messages", "messages": [msg]})
                return
            except asyncio.TimeoutError:
                # Check inbox file as fallback (in case message was written directly)
                if session.work_dir:
                    messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
                    if messages:
                        await ws.send_json({"type": "messages", "messages": messages})
                        await send_to_browser({
                            "type": "inbox_update",
                            "session_id": session_id,
                            "count": 0,
                        })
                        return
                # Send keepalive ping
                try:
                    await ws.send_json({"type": "ping"})
                except Exception:
                    break
    except WebSocketDisconnect:
        log.info("[%s] Wait WS disconnected", session_id)
    except Exception as e:
        log.warning("[%s] Wait WS error: %s", session_id, e)
    finally:
        session.activity = ""
        session.tool_name = ""
        session.tool_input = {}
        session.set_state(AgentState.PROCESSING)
        await _save_activity(session, "Processing")
        await send_to_browser({
            "type": "session_status",
            "session_id": session_id,
            "state": session.state.value,
            "activity": session.activity,
            "tool_name": session.tool_name,
            "tool_input": session.tool_input,
        })
        if hasattr(session, "_wait_queue"):
            del session._wait_queue


# --- Project Status API ---

@app.post("/api/project-status/{session_id}")
async def set_project_status(session_id: str, request: Request):
    """Set project status for a session (used by clawmux project command)."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "session not found"}, status_code=404)
    data = await request.json()
    if "project" in data:
        session.project = data["project"]
        # Note: project_slug (organizational folder) is NOT updated here.
        # Agents set their working repo via this endpoint; folder assignment
        # is managed separately by the user via the UI / folder API.
    session.project_repo = data.get("repo", data.get("area", session.project_repo))
    if "role" in data:
        role_val = data["role"].lower()
        rules_dir = Path(__file__).parent / "templates" / "rules"
        valid_roles = {f.stem for f in rules_dir.glob("*.md") if f.is_file()}
        if valid_roles and role_val not in valid_roles:
            return JSONResponse(
                {"error": f"Invalid role '{role_val}'. Valid: {sorted(valid_roles)}"},
                status_code=400,
            )
        session.role = role_val
    if "task" in data:
        session.task = data["task"]
    log.info("[%s] Project status: %s / %s (role=%s, task=%s)",
             session_id, session.project, session.project_repo, session.role, session.task)
    await send_to_browser({
        "type": "project_status",
        "session_id": session_id,
        "project": session.project,
        "repo": session.project_repo,
        "role": session.role,
        "task": session.task,
    })
    # Persist to agents.json (authoritative store)
    await session_mgr._sync_agent_store(session.voice, session)
    # Write role rules to .claude/CLAUDE.md (Claude Code auto-detects the change)
    if "role" in data and session.work_dir:
        await template_renderer.render_role_to_file(session.voice, Path(session.work_dir))
        await _inbox_write_and_notify(session, {
            "type": "system",
            "content": f"Your role has been updated to: {session.role}. Your role rules file has been rewritten — Claude Code will pick up the changes automatically.",
        })
    return JSONResponse({"ok": True})


# --- Debug log from browser ---
_browser_debug_log: list[str] = []

@app.post("/api/debug-log")
async def debug_log(request: Request):
    body = await request.json()
    msg = body.get("msg", "")
    if msg:
        _browser_debug_log.append(msg)
        if len(_browser_debug_log) > 100:
            _browser_debug_log.pop(0)
    return JSONResponse({"ok": True})

@app.get("/api/debug-log")
async def get_debug_log():
    return JSONResponse({"lines": _browser_debug_log})


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")

@app.get("/api/debug/status")
async def debug_status():
    """Run `clawmux status` and return plain-text output (ANSI stripped)."""
    try:
        result = await asyncio.to_thread(
            subprocess.run,
            ["clawmux", "status"],
            capture_output=True, text=True, timeout=5,
        )
        raw = result.stdout or result.stderr or "(no output)"
        clean = _ANSI_RE.sub("", raw)
        return JSONResponse({"output": clean})
    except FileNotFoundError:
        return JSONResponse({"output": "clawmux not found in PATH"})
    except subprocess.TimeoutExpired:
        return JSONResponse({"output": "clawmux status timed out"})
    except Exception as e:
        return JSONResponse({"output": f"Error: {e}"})


# --- Claude Code Hook Endpoint ---

def _session_from_cwd(cwd: str) -> "SessionInfo | None":
    """Map a working directory path to its ClawMux session.

    Claude Code hooks send the agent's cwd (e.g. ~/.clawmux/sessions/am_echo).
    We match that against each session's work_dir.
    """
    for session in session_mgr.sessions.values():
        if session.work_dir and cwd.rstrip("/") == session.work_dir.rstrip("/"):
            return session
    return None


_TOOL_STATUS_MAP = {
    "Glob": "Finding files",
    "Agent": "Spawning agent",
    "WebSearch": "Searching web",
    "NotebookEdit": "Editing notebook",
}


def _tool_activity_text(tool_name: str, tool_input: dict) -> str:
    """Convert a tool name + input into a human-readable status string."""
    if tool_name == "Read":
        path = tool_input.get("file_path", "")
        return f"Reading {Path(path).name}" if path else "Reading file"
    if tool_name == "Write":
        path = tool_input.get("file_path", "")
        return f"Writing {Path(path).name}" if path else "Writing file"
    if tool_name == "Edit":
        path = tool_input.get("file_path", "")
        return f"Editing {Path(path).name}" if path else "Editing file"
    if tool_name == "Bash":
        cmd = tool_input.get("command", "").strip()
        desc = tool_input.get("description", "")
        if desc:
            return f"Running {desc}"
        preview = cmd[:60] + ("…" if len(cmd) > 60 else "")
        return f"Running {preview}" if preview else "Running command"
    if tool_name == "Grep":
        pattern = tool_input.get("pattern", "")
        return f"Searching for {pattern}" if pattern else "Searching"
    if tool_name == "WebFetch":
        url = tool_input.get("url", "")
        try:
            from urllib.parse import urlparse
            domain = urlparse(url).netloc
            return f"Fetching {domain}" if domain else "Fetching URL"
        except Exception:
            return "Fetching URL"
    return _TOOL_STATUS_MAP.get(tool_name, tool_name)



@app.post("/api/hooks/tool-status")
async def hook_tool_status(request: Request):
    """Receive Claude Code PreToolUse/PostToolUse hooks to update live session status."""
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({})

    event = data.get("hook_event_name", "")

    # Prefer ClawMux-Session header, fall back to legacy X-ClawMux-Session, then cwd
    clawmux_sid = request.headers.get("clawmux-session", "") or request.headers.get("x-clawmux-session", "")
    session = session_mgr.sessions.get(clawmux_sid) if clawmux_sid else None
    if not session and clawmux_sid:
        # Legacy: CLAWMUX_SESSION_ID may be voice_id (e.g. "bf_alice") not label ("alice")
        session = next((s for s in session_mgr.sessions.values() if s.voice == clawmux_sid), None)
    if not session:
        cwd = data.get("cwd", "")
        session = _session_from_cwd(cwd)
    if not session:
        log.warning("[hook] %s: session not found (header=%r, known=%s)", event, clawmux_sid, list(session_mgr.sessions.keys()))
        return JSONResponse({})

    response_json = {}

    if event in ("PostToolUse", "PostToolUseFailure"):
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        session.activity = ""
        session.tool_name = ""
        session.tool_input = {}
        # Stay in PROCESSING after each tool call — Claude is deciding next action
        if session.state in (AgentState.PROCESSING, AgentState.IDLE):
            session.set_state(AgentState.PROCESSING)
            await send_to_browser({
                "type": "session_status",
                "session_id": session.session_id,
                "state": session.state.value,
                "activity": session.activity,
                "tool_name": session.tool_name,
                "tool_input": session.tool_input,
            })
            await _save_activity(session, "Processing")
    elif event == "Stop":
        pass  # HTTP Stop hooks cannot block Claude; stop-check-inbox.sh handles idle signaling
    elif event == "PreToolUse":
        # PreToolUse means the agent is actively making a tool call.
        # Don't cancel pending injections — tmux buffers input so delivery is safe at any time.
        if session.state == AgentState.IDLE:
            session.set_state(AgentState.PROCESSING)
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        session.tool_name = tool_name
        session.tool_input = tool_input
        session.activity = _tool_activity_text(tool_name, tool_input)
        # Log beginning of tool use
        await _save_activity(session, session.activity)
    elif event == "Notification":
        # Notification hook — relay to browser and check inbox
        notification = data.get("notification", {})
        await send_to_browser({
            "type": "notification",
            "session_id": session.session_id,
            "notification": notification,
        })
    elif event == "SessionStart":
        session.activity = "Starting"
        await _save_activity(session, "Starting")
    elif event == "PreCompact":
        session.set_state(AgentState.COMPACTING)
        session.activity = "Compacting"
        await _save_activity(session, "Compacting")
        # Inject CLAUDE.md + role rules into the compaction summary so instructions survive
        if session.work_dir:
            try:
                def _read_instructions() -> str:
                    parts = []
                    claude_md_path = os.path.join(session.work_dir, "CLAUDE.md")
                    if os.path.exists(claude_md_path):
                        parts.append(open(claude_md_path).read())
                    rules_dir = os.path.join(session.work_dir, ".claude", "rules")
                    if os.path.isdir(rules_dir):
                        for fname in sorted(os.listdir(rules_dir)):
                            if fname.endswith(".md"):
                                fpath = os.path.join(rules_dir, fname)
                                parts.append(f"# Rule: {fname}\n" + open(fpath).read())
                    return "\n\n".join(parts)

                instructions = await asyncio.to_thread(_read_instructions)
                if instructions:
                    response_json = {
                        "hookSpecificOutput": {
                            "hookEventName": event,
                            "additionalContext": (
                                "IMPORTANT: Your instructions and role rules are being re-injected before "
                                "compaction so they survive into the new context window. "
                                "Re-read and internalize them:\n\n" + instructions
                            ),
                        }
                    }
            except Exception:
                pass
    else:
        return JSONResponse({})

    # PostToolUse doesn't broadcast — "Processing..." is transient; the next
    # PreToolUse or wait WS connect will broadcast the real state.
    if event not in ("PostToolUse", "PostToolUseFailure"):
        msg = {
            "type": "session_status",
            "session_id": session.session_id,
            "state": session.state.value,
            "activity": session.activity,
            "tool_name": session.tool_name,
            "tool_input": session.tool_input,
        }
        if event == "Stop":
            msg["agent_idle"] = True
        await send_to_browser(msg)
    return JSONResponse(response_json)


# --- REST API ---

@app.get("/api/sessions")
async def list_sessions():
    return JSONResponse(session_mgr.list_sessions())


@app.post("/api/sessions")
async def spawn_session(request: Request):
    try:
        body = await request.json() if request.headers.get("content-type") == "application/json" else {}
        label = body.get("label", "")
        voice = body.get("voice", "")
        project = _resolve_slug(body.get("project")) if body.get("project") else None
        session = await session_mgr.spawn_session(label, voice, project=project)
        # Notify browser of the new session so the sidebar updates immediately
        await send_to_browser({"type": "session_spawned", "session": session.to_dict()})
        # Show thinking indicator while agent boots (state stays STARTING)
        await send_to_browser({"session_id": session.session_id, "type": "thinking"})
        return JSONResponse(session.to_dict())
    except RuntimeError as e:
        return JSONResponse({"error": str(e)}, status_code=503)
    except TimeoutError as e:
        return JSONResponse({"error": str(e)}, status_code=504)
    except Exception as e:
        log.error("Spawn failed: %s: %s", type(e).__name__, e)
        return JSONResponse({"error": str(e)}, status_code=500)


@app.delete("/api/sessions/{session_id}")
async def terminate_session(session_id: str):
    await session_mgr.terminate_session(session_id)
    await send_to_browser({"type": "session_terminated", "session_id": session_id})
    return JSONResponse({"status": "terminated"})


@app.post("/api/sessions/{session_id}/restart")
async def restart_session(session_id: str):
    """Kill and respawn an agent session, preserving the voice and project."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "session not found"}, status_code=404)
    voice = session.voice
    project_slug = session.project_slug
    # Terminate the existing session
    await session_mgr.terminate_session(session_id)
    await send_to_browser({"type": "session_terminated", "session_id": session_id})
    # Respawn with the same voice and project
    new_session = await session_mgr.spawn_session(voice=voice, project=project_slug)
    await send_to_browser({"type": "session_spawned", "session": new_session.to_dict()})
    await send_to_browser({"session_id": new_session.session_id, "type": "thinking"})
    return JSONResponse({"status": "restarted", "session_id": new_session.session_id})


@app.post("/api/sessions/{session_id}/interrupt")
async def interrupt_session(session_id: str):
    """Send Escape to a running agent to soft-interrupt it."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "session not found"}, status_code=404)
    tmux_name = session.tmux_session
    try:
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", tmux_name, "Escape",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await proc.communicate()
        if proc.returncode != 0:
            log.warning("Failed to interrupt %s: %s", tmux_name, stderr.decode().strip())
            return JSONResponse({"error": "tmux send-keys failed"}, status_code=500)
    except Exception as e:
        log.error("Interrupt error for %s: %s", tmux_name, e)
        return JSONResponse({"error": str(e)}, status_code=500)
    log.info("Interrupted session %s (tmux: %s)", session_id, tmux_name)

    # Signal idle so hub re-delivers any pending inbox messages after interrupt
    asyncio.create_task(asyncio.sleep(3))  # Let Claude Code settle before hub can inject

    return JSONResponse({"status": "interrupted"})


_MAX_UPLOAD_SIZE = 50 * 1024 * 1024  # 50 MB

@app.post("/api/sessions/{session_id}/upload")
async def upload_file(session_id: str, file: UploadFile):
    """Accept a file upload and deliver it to the agent's work directory."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "session not found"}, status_code=404)
    if not session.work_dir:
        return JSONResponse({"error": "session has no work directory"}, status_code=400)
    if not file.filename:
        return JSONResponse({"error": "no filename"}, status_code=400)

    # Read file with size limit
    contents = await file.read()
    if len(contents) > _MAX_UPLOAD_SIZE:
        return JSONResponse({"error": "file too large (50MB max)"}, status_code=413)

    # Save to uploads/ in the agent's work dir
    safe_name = Path(file.filename).name  # strip directory components
    uploads_dir = Path(session.work_dir) / "uploads"
    uploads_dir.mkdir(parents=True, exist_ok=True)
    dest = uploads_dir / safe_name
    dest.write_bytes(contents)

    # Format size for display
    size = len(contents)
    if size >= 1024 * 1024:
        size_str = f"{size / (1024 * 1024):.1f} MB"
    elif size >= 1024:
        size_str = f"{size / 1024:.1f} KB"
    else:
        size_str = f"{size} B"

    # Notify the agent via inbox
    umid = _gen_msg_id()
    await _inbox_write_and_notify(session, {
        "id": umid,
        "from": "user",
        "type": "file_upload",
        "content": f"User uploaded a file: uploads/{safe_name}",
    })

    # Show in chat
    await send_to_browser({
        "session_id": session_id,
        "type": "user_text",
        "text": f"\U0001F4CE Uploaded {safe_name} ({size_str})",
        "msg_id": umid,
    })
    await asyncio.to_thread(history.append, session.voice, session.label, "user",
                   f"\U0001F4CE Uploaded {safe_name} ({size_str})",
                   _hist_prefix(session), msg_id=umid)

    log.info("[%s] File uploaded: %s (%s)", session_id, safe_name, size_str)
    return JSONResponse({"status": "ok", "path": f"uploads/{safe_name}", "size": size_str})


@app.post("/api/shutdown")
async def shutdown_hub(request: Request):
    """Shut down the hub. Use mode=reload to keep sessions alive."""
    global _shutdown_mode
    body = await request.json() if request.headers.get("content-type") == "application/json" else {}
    mode = body.get("mode", "full")  # "full" or "reload"
    _shutdown_mode = mode
    log.info("Shutdown requested via API (mode=%s)", mode)

    async def do_shutdown():
        await asyncio.sleep(0.3)  # Let the response send first
        if mode == "reload":
            log.info("Hub reloading — keeping tmux sessions alive")
        else:
            log.info("Hub shutting down — terminating all sessions")
            for sid in list(session_mgr.sessions):
                try:
                    await session_mgr.terminate_session(sid)
                except Exception:
                    pass
        broker.stop()
        log.info("Shutdown cleanup done, exiting")
        os._exit(0)

    asyncio.create_task(do_shutdown())
    return JSONResponse({"status": "shutting_down", "mode": mode})


@app.put("/api/sessions/{session_id}/voice")
async def set_session_voice(session_id: str, request: Request):
    data = await request.json()
    voice = data.get("voice", "af_sky")
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "Session not found"}, status_code=404)
    session.voice = voice
    log.info("[%s] Voice changed to %s", session_id, voice)
    return JSONResponse({"voice": voice})


@app.put("/api/sessions/{session_id}/speed")
async def set_session_speed(session_id: str, request: Request):
    data = await request.json()
    speed = float(data.get("speed", 1.0))
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "Session not found"}, status_code=404)
    session.speed = speed
    log.info("[%s] Speed changed to %s", session_id, speed)
    return JSONResponse({"speed": speed})


# --- Agent Metadata (v0.7.3 centralized agents.json) ---


@app.get("/api/agents")
async def list_agents():
    """Return all agents from agents.json."""
    agents = await agents_store.all_agents()
    return JSONResponse({vid: entry.to_dict() for vid, entry in agents.items()})


@app.get("/api/agents/{voice_id}")
async def get_agent(voice_id: str):
    """Return a single agent's metadata from agents.json."""
    agent = await agents_store.get(voice_id)
    if agent is None:
        return JSONResponse({"error": "Agent not found"}, status_code=404)
    return JSONResponse(agent.to_dict())


@app.put("/api/agents/{voice_id}")
async def update_agent(voice_id: str, request: Request):
    """Update an agent's metadata in agents.json."""
    body = await request.json()
    updated = await agents_store.update(voice_id, **body)
    if updated is None:
        return JSONResponse({"error": "Agent not found"}, status_code=404)
    log.info("[agents] Updated %s: %s", voice_id, list(body.keys()))
    return JSONResponse(updated.to_dict())


@app.post("/api/agents/{voice_id}/assign")
async def assign_agent(voice_id: str, request: Request):
    """Change an agent's project and/or role assignment."""
    body = await request.json()
    fields = {k: body[k] for k in ("project", "role", "repo") if k in body}
    if not fields:
        return JSONResponse({"error": "No assignment fields provided"}, status_code=400)
    updated = await agents_store.update(voice_id, **fields)
    if updated is None:
        return JSONResponse({"error": "Agent not found"}, status_code=404)
    log.info("[agents] Assigned %s → project=%s role=%s repo=%s",
             voice_id, updated.project, updated.role, updated.repo)
    # Auto-regenerate CLAUDE.md for the reassigned agent
    session = next((s for s in session_mgr.sessions.values() if s.voice == voice_id), None)
    if session and session.work_dir:
        await template_renderer.render_to_file(voice_id, Path(session.work_dir))
    return JSONResponse(updated.to_dict())


@app.post("/api/agents/regenerate")
async def regenerate_all_templates():
    """Regenerate CLAUDE.md for all active agents."""
    template_renderer.reload_template()
    count = await template_renderer.render_all(session_mgr.sessions)
    return JSONResponse({"regenerated": count})


@app.post("/api/agents/{voice_id}/regenerate")
async def regenerate_template(voice_id: str):
    """Regenerate CLAUDE.md for a single agent."""
    template_renderer.reload_template()
    session = next((s for s in session_mgr.sessions.values() if s.voice == voice_id), None)
    if not session or not session.work_dir:
        return JSONResponse({"error": "Agent not found or not active"}, status_code=404)
    ok = await template_renderer.render_to_file(voice_id, Path(session.work_dir))
    if not ok:
        return JSONResponse({"error": "Agent not in agents.json"}, status_code=404)
    return JSONResponse({"regenerated": voice_id})


# --- Agent idle/active signals (used by stop hook for tmux-push delivery) ---

@app.post("/api/agents/{session_id}/idle")
async def agent_idle(session_id: str):
    """Signal that an agent has finished responding and is now idle.

    Called by the stop hook (stop-check-inbox.sh). Transitions the agent to
    IDLE state and schedules a tmux injection if inbox has pending messages.
    """
    session = session_mgr.sessions.get(session_id)
    if not session:
        # Legacy: CLAWMUX_SESSION_ID may be set to voice_id (e.g. "bf_alice") not label ("alice")
        session = next((s for s in session_mgr.sessions.values() if s.voice == session_id), None)
    if not session or not session.work_dir:
        return JSONResponse({"ok": False, "reason": "session not found"})

    session.set_state(AgentState.IDLE)
    session.activity = ""
    session.tool_name = ""
    session.tool_input = {}
    await _save_activity(session, "Idle")
    await send_to_browser({"session_id": session_id, "type": "listening", "state": "idle"})
    await send_to_browser({
        "type": "session_status",
        "session_id": session_id,
        "state": session.state.value,
        "activity": "",
        "tool_name": "",
        "tool_input": {},
    })

    # Schedule injection if inbox has messages (lock in _inject_inbox serializes delivery)
    count = await asyncio.to_thread(inbox.peek, session.work_dir)
    if count > 0:
        task = asyncio.create_task(_inject_inbox(session, session_id))
        _pending_injections[session_id] = task

    return JSONResponse({"ok": True, "pending": count})


@app.post("/api/agents/{session_id}/active")
async def agent_active(session_id: str):
    """Cancel any pending tmux injection for a session.

    Called by PreToolUse hook when the agent starts a tool call — injection is
    no longer needed since the agent is already working.
    """
    prev = _pending_injections.pop(session_id, None)
    if prev and not prev.done():
        prev.cancel()
    return JSONResponse({"ok": True})


# --- Walking Mode ---

@app.post("/api/agents/{session_id}/walking")
async def set_walking_mode(session_id: str, request: Request):
    """Toggle walking mode for a session.

    When walking_mode is on, every tmux injection prepends a reminder for the
    agent to respond in plain spoken text — no markdown, no special formatting.
    """
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"ok": False, "reason": "session not found"})
    data = await request.json()
    enabled = bool(data.get("enabled", True))
    session.walking_mode = enabled
    log.info("[%s] Walking mode: %s", session_id, "on" if enabled else "off")
    await send_to_browser({
        "type": "session_status",
        "session_id": session_id,
        "state": session.state.value,
        "activity": session.activity,
        "tool_name": session.tool_name,
        "tool_input": session.tool_input,
        "walking_mode": enabled,
    })
    note = "on" if enabled else "off"
    await _inbox_write_and_notify(session, {
        "type": "system",
        "content": f"Walking mode is now {note}." + (" Respond in plain spoken text only — no markdown, no underscores, no special formatting." if enabled else " You may use normal formatting again."),
    })
    return JSONResponse({"ok": True, "walking_mode": enabled})


# --- Roles ---

@app.get("/api/roles")
async def list_roles():
    """Return available roles derived from template files in server/templates/rules/."""
    rules_dir = Path(__file__).parent / "templates" / "rules"
    roles = sorted(
        f.stem for f in rules_dir.glob("*.md") if f.is_file()
    )
    return JSONResponse({"roles": roles})


# --- Project Management ---

@app.get("/api/projects")
async def list_projects():
    """Return projects in {projects: {slug: {...}}, active_project: slug} format."""
    # Sync: ensure any project seen in live sessions exists in projects.json
    # and voices are placed in the right folder per session.project_slug
    _sync_projects_from_sessions()
    projects_dict = {}
    for p in project_mgr.list_projects():
        slug = p.pop("slug")
        p.pop("active", None)
        projects_dict[slug] = p
    return JSONResponse({
        "projects": projects_dict,
        "active_project": project_mgr.active_project,
    })


def _sync_projects_from_sessions():
    """Ensure projects.json reflects actual session project_slug values.

    - Creates any project that sessions reference but doesn't exist yet
    - Moves each voice to the project its live session belongs to
    """
    # Build desired mapping: voice → project_slug from live sessions
    voice_to_slug: dict[str, str] = {}
    for s in session_mgr.sessions.values():
        if s.voice:
            slug = getattr(s, "project_slug", None) or "default"
            voice_to_slug[s.voice] = slug

    if not voice_to_slug:
        return

    # Only sync voices for folders that actually exist — never auto-create folders
    # Remap any session pointing at an unknown slug back to default
    for voice, slug in list(voice_to_slug.items()):
        if slug not in project_mgr.projects:
            voice_to_slug[voice] = "default"

    # Rebuild each project's voices list from session truth
    new_voices: dict[str, list[str]] = {slug: [] for slug in project_mgr.projects}
    for voice, slug in voice_to_slug.items():
        if slug in new_voices:
            new_voices[slug].append(voice)

    # Preserve voices not in any live session (agents that may be offline)
    all_pool = [v[0] for v in __import__('hub_config').VOICE_POOL]
    unassigned = [v for v in all_pool if v not in voice_to_slug]
    # Leave unassigned voices where they currently are in projects.json
    for slug, proj in project_mgr.projects.items():
        for v in proj.get("voices", []):
            if v in unassigned and v not in new_voices.get(slug, []):
                new_voices.setdefault(slug, []).append(v)

    # Apply changes
    changed = False
    for slug, voices in new_voices.items():
        if slug in project_mgr.projects:
            current = project_mgr.projects[slug].get("voices", [])
            if sorted(current) != sorted(voices):
                project_mgr.reorder_voices(slug, voices)
                changed = True
    if changed:
        import logging
        logging.getLogger("hub.projects").info("Synced project voices from live sessions")


@app.post("/api/projects")
async def create_project(request: Request):
    data = await request.json()
    slug = data.get("slug", "").strip().lower().replace(" ", "-")
    name = data.get("name", slug)
    if not slug:
        return JSONResponse({"error": "slug is required"}, status_code=400)
    voices = data.get("voices")  # Optional: list of voice IDs to use
    try:
        project = project_mgr.create_project(slug, name, voices=voices)
        # Populate agents.json with project entry and default agent assignments
        from agents_store import ProjectEntry
        await agents_store.set_project(slug, ProjectEntry(display_name=name))
        voice_ids = project.get("voices", [])
        for vid in voice_ids:
            agent = await agents_store.get(vid)
            if agent is None:
                from agents_store import AgentEntry
                await agents_store.set(vid, AgentEntry(project=slug))
            else:
                # Update project assignment for existing agent
                await agents_store.update(vid, project=slug)
        # Regenerate CLAUDE.md for assigned agents
        for vid in voice_ids:
            session = next((s for s in session_mgr.sessions.values() if s.voice == vid), None)
            if session and session.work_dir:
                await template_renderer.render_to_file(vid, Path(session.work_dir))
        await send_to_browser({"type": "project_created", "slug": slug, "name": name})
        return JSONResponse(project)
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)


@app.post("/api/projects/{slug}/copy-history")
async def copy_project_history(slug: str, request: Request):
    """Copy conversation history from one project to another."""
    data = await request.json()
    source_slug = data.get("source", "default")
    if slug not in project_mgr.projects:
        return JSONResponse({"error": f"Project '{slug}' not found"}, status_code=404)
    if source_slug not in project_mgr.projects:
        return JSONResponse({"error": f"Source project '{source_slug}' not found"}, status_code=404)
    # Copy history for each voice shared between source and target
    source_voices = project_mgr.projects[source_slug].get("voices", [])
    target_voices = project_mgr.projects[slug].get("voices", [])
    src_prefix = project_mgr.get_history_prefix(source_slug)
    tgt_prefix = project_mgr.get_history_prefix(slug)
    copied = 0
    # Copy voices that exist in both projects (same voice IDs)
    shared = set(source_voices) & set(target_voices)
    for voice_id in shared:
        try:
            history.copy_history(voice_id, src_prefix, tgt_prefix)
            copied += 1
        except Exception as e:
            log.warning("Failed to copy history for %s: %s", voice_id, e)
    return JSONResponse({"copied": copied, "total": len(source_voices)})


@app.post("/api/projects/{slug}/activate")
async def activate_project(slug: str):
    try:
        project_mgr.switch_project(slug)
        # Notify browser of project switch
        await send_to_browser({"type": "project_switched", "project": slug})
        return JSONResponse({"active_project": slug})
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=404)


@app.put("/api/projects/{slug}/voices")
async def reorder_voices(slug: str, request: Request):
    data = await request.json()
    voices = data.get("voices", [])
    if not voices or not isinstance(voices, list):
        return JSONResponse({"error": "voices array is required"}, status_code=400)
    try:
        project_mgr.reorder_voices(slug, voices)
        return JSONResponse({"slug": slug, "voices": voices})
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=404)


@app.put("/api/projects/{slug}")
async def rename_project(slug: str, request: Request):
    import re as _re
    data = await request.json()
    new_name = data.get("name", "").strip()
    if not new_name:
        return JSONResponse({"error": "name is required"}, status_code=400)
    # Derive new slug from new name (folders are purely visual — slug follows name)
    new_slug = _re.sub(r"[^a-z0-9]+", "-", new_name.lower()).strip("-") or slug
    if new_slug == slug:
        new_slug = None  # no slug change
    try:
        result = project_mgr.rename_project(slug, new_name, new_slug)
        actual_slug = result["slug"]
        # Migrate any live sessions still referencing the old slug
        if new_slug:
            for s in session_mgr.sessions.values():
                if getattr(s, "project_slug", None) == slug:
                    s.project_slug = actual_slug
        await send_to_browser({"type": "project_renamed", "old_slug": slug, "slug": actual_slug, "name": new_name})
        return JSONResponse(result)
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)


@app.delete("/api/projects/{slug}")
async def delete_project(slug: str):
    try:
        was_active = project_mgr.active_project == slug
        project_mgr.delete_project(slug)
        # Notify browser so sidebar/header refresh immediately
        await send_to_browser({"type": "project_deleted", "slug": slug})
        if was_active:
            await send_to_browser({"type": "project_switched", "project": project_mgr.active_project})
        return JSONResponse({"status": "deleted", "slug": slug})
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)


# ── Group Chat API ────────────────────────────────────────────────────────────

_GROUPS_DIR = hub_config.CLAWMUX_HOME / "groups"
_GROUPS_META = hub_config.CLAWMUX_HOME / "groups.json"


def _label_for_voice(voice_id: str) -> str:
    """Derive display label from voice ID (e.g. 'af_sky' → 'Sky')."""
    part = voice_id.split("_", 1)[-1] if "_" in voice_id else voice_id
    return part.capitalize()


def _save_groups() -> None:
    import fcntl
    data = {
        name: {"id": g["id"], "name": g["name"], "voices": list(g["voices"])}
        for name, g in _group_chats.items()
    }
    try:
        with open(_GROUPS_META, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            json.dump(data, f)
            fcntl.flock(f, fcntl.LOCK_UN)
    except Exception:
        pass


def _load_groups() -> None:
    if not _GROUPS_META.exists():
        return
    try:
        data = json.loads(_GROUPS_META.read_text())
        for name, g in data.items():
            _group_chats[name] = {
                "id": g["id"],
                "name": g["name"],
                "voices": list(g.get("voices", g.get("session_ids", []))),
            }
    except Exception:
        pass


def _group_history_path(group_id: str):
    d = _GROUPS_DIR / group_id
    d.mkdir(parents=True, exist_ok=True)
    return d / "history.json"


def _find_group_for_message(msg_id: str) -> dict | None:
    """Return the group chat dict that contains a message with the given ID, or None."""
    for g in _group_chats.values():
        for msg in _load_group_history(g["id"]):
            if msg.get("id") == msg_id:
                return g
    return None


def _load_group_history(group_id: str) -> list:
    p = _group_history_path(group_id)
    if not p.exists():
        return []
    try:
        return json.loads(p.read_text()).get("messages", [])
    except Exception:
        return []


def _append_group_history(group_id: str, role: str, text: str, sender: str = "",
                           msg_id: str | None = None, parent_id: str | None = None,
                           bare_ack: bool = False, sender_voice: str = "") -> None:
    import fcntl
    p = _group_history_path(group_id)
    try:
        data = json.loads(p.read_text()) if p.exists() else {}
    except Exception:
        data = {}
    msgs = data.get("messages", [])
    entry: dict = {"role": role, "text": text, "ts": time.time()}
    if sender:
        entry["sender"] = sender
    if msg_id:
        entry["id"] = msg_id
    if parent_id:
        entry["parent_id"] = parent_id
    if bare_ack:
        entry["bare_ack"] = True
    if sender_voice:
        entry["sender_voice"] = sender_voice
    msgs.append(entry)
    data["messages"] = msgs
    try:
        with open(p, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                f.write(json.dumps(data, indent=2))
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except Exception as e:
        log.error("Failed to save group history %s: %s", group_id, e)


def _group_to_dict(g: dict) -> dict:
    """Serialize a group chat dict, resolving voices to member info."""
    members = []
    # Build a voice→session lookup for online resolution
    voice_to_session: dict[str, object] = {}
    for s in session_mgr.sessions.values():
        if s.voice and s.voice not in voice_to_session:
            voice_to_session[s.voice] = s
    for v in g.get("voices", []):
        s = voice_to_session.get(v)
        members.append({
            "voice": v,
            "label": s.label if s else _label_for_voice(v),
            "online": s is not None,
            "session_id": s.session_id if s else None,
        })
    return {"id": g["id"], "name": g["name"], "voices": list(g.get("voices", [])), "members": members}


@app.get("/api/groupchats")
async def list_groupchats():
    return JSONResponse({"groups": [_group_to_dict(g) for g in _group_chats.values()]})


@app.post("/api/groupchats")
async def create_groupchat(request: Request):
    data = await request.json()
    name = (data.get("name") or "").strip()
    if not name:
        return JSONResponse({"error": "name is required"}, status_code=400)
    key = name.lower()
    if key in _group_chats:
        return JSONResponse({"error": f"group '{name}' already exists"}, status_code=409)
    gid = "gc-" + uuid.uuid4().hex[:8]
    voices = data.get("voices", [])
    _group_chats[key] = {"id": gid, "name": name, "voices": list(voices)}
    _save_groups()
    await send_to_browser({"type": "groupchat_created", "group": _group_to_dict(_group_chats[key])})
    return JSONResponse(_group_to_dict(_group_chats[key]))


@app.delete("/api/groupchats/{name}")
async def delete_groupchat(name: str):
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    g = _group_chats.pop(key)
    _save_groups()
    await send_to_browser({"type": "groupchat_deleted", "group_id": g["id"], "name": g["name"]})
    return JSONResponse({"status": "deleted", "name": g["name"]})


@app.post("/api/groupchats/{name}/add")
async def groupchat_add_member(name: str, request: Request):
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    data = await request.json()
    # Accept voice ID directly; also resolve session_id → voice for backwards compat
    voice = data.get("voice", "")
    if not voice:
        sid = data.get("session_id", "")
        if sid:
            s = session_mgr.sessions.get(sid)
            voice = s.voice if s else ""
    if not voice:
        return JSONResponse({"error": "voice is required"}, status_code=400)
    g = _group_chats[key]
    if voice not in g["voices"]:
        g["voices"].append(voice)
    _save_groups()
    await send_to_browser({"type": "groupchat_updated", "group": _group_to_dict(g)})
    return JSONResponse(_group_to_dict(g))


@app.post("/api/groupchats/{name}/remove")
async def groupchat_remove_member(name: str, request: Request):
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    data = await request.json()
    voice = data.get("voice", "")
    if not voice:
        sid = data.get("session_id", "")
        if sid:
            s = session_mgr.sessions.get(sid)
            voice = s.voice if s else ""
    g = _group_chats[key]
    if voice and voice in g["voices"]:
        g["voices"].remove(voice)
    _save_groups()
    await send_to_browser({"type": "groupchat_updated", "group": _group_to_dict(g)})
    return JSONResponse(_group_to_dict(g))


@app.post("/api/groupchats/{name}/message")
async def groupchat_send_message(name: str, request: Request):
    """Send a message to all members of a named group chat."""
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    data = await request.json()
    text = data.get("text", "").strip()
    sender = data.get("sender", "")  # label of sender, or empty for user
    if not text:
        return JSONResponse({"error": "text is required"}, status_code=400)
    g = _group_chats[key]
    msg_id = _gen_msg_id()
    role = "user" if not sender else "assistant"
    # Write to group history
    await asyncio.to_thread(
        _append_group_history, g["id"], role, text, sender, msg_id
    )
    # Deliver to all online members' inboxes (look up sessions by voice)
    delivered = []
    voice_to_session: dict[str, object] = {}
    for s in session_mgr.sessions.values():
        if s.voice and s.voice not in voice_to_session:
            voice_to_session[s.voice] = s
    for v in g.get("voices", []):
        session = voice_to_session.get(v)
        if not session or not session.work_dir:
            continue
        # Don't deliver back to the sender
        if sender and session.label.lower() == sender.lower():
            continue
        inbox_msg = {
            "id": msg_id,
            "type": "group",
            "from": sender or "user",
            "content": text,
            "group_name": g["name"],
            "group_id": g["id"],
        }
        await _inbox_write_and_notify(session, inbox_msg)
        delivered.append(session.session_id)
    # Notify browser of new group history message
    await send_to_browser({
        "type": "groupchat_message",
        "group_id": g["id"],
        "group_name": g["name"],
        "message": {"id": msg_id, "role": role, "text": text, "sender": sender, "ts": time.time()},
    })
    return JSONResponse({"status": "sent", "msg_id": msg_id, "delivered_to": delivered, "group": g["name"]})


@app.get("/api/groupchats/{name}/history")
async def groupchat_history(name: str):
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    g = _group_chats[key]
    messages = await asyncio.to_thread(_load_group_history, g["id"])
    return JSONResponse({"group_id": g["id"], "name": g["name"], "messages": messages})


@app.post("/api/groupchats/{name}/ack")
async def groupchat_ack_message(name: str, request: Request):
    """Acknowledge a group chat message (thumbs up)."""
    key = name.lower()
    if key not in _group_chats:
        return JSONResponse({"error": "group not found"}, status_code=404)
    data = await request.json()
    msg_id = (data.get("msg_id") or "").strip()
    if not msg_id:
        return JSONResponse({"error": "msg_id required"}, status_code=400)
    g = _group_chats[key]
    ack_id = _gen_msg_id()
    await asyncio.to_thread(_append_group_history, g["id"], "user", "",
                            sender="You", msg_id=ack_id, parent_id=msg_id, bare_ack=True)
    await send_to_browser({
        "type": "groupchat_ack",
        "group_id": g["id"],
        "msg_id": msg_id,
        "ack_id": ack_id,
        "sender": "You",
        "sender_voice": "",
    })
    return JSONResponse({"status": "acked", "ack_id": ack_id})


@app.post("/api/groupchats/reorder")
async def groupchat_reorder(request: Request):
    """Reorder group chats. Body: {order: [group_id, ...]}"""
    data = await request.json()
    order = data.get("order") or []
    # Build new ordered dict
    id_to_key = {g["id"]: k for k, g in _group_chats.items()}
    new_chats: dict = {}
    seen = set()
    for gid in order:
        k = id_to_key.get(gid)
        if k and k not in seen:
            new_chats[k] = _group_chats[k]
            seen.add(k)
    # Append any not in order list
    for k, g in _group_chats.items():
        if k not in seen:
            new_chats[k] = g
    _group_chats.clear()
    _group_chats.update(new_chats)
    _save_group_chats()
    return JSONResponse({"status": "ok"})


@app.get("/api/history/{voice_id}")
async def get_history(voice_id: str, request: Request):
    # Use project from query param or active project
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    messages = await asyncio.to_thread(history.load, voice_id, prefix)
    # Cursor-based filtering: return only messages after the given ID (reconnect sync)
    after_id = request.query_params.get("after")
    if after_id:
        idx = None
        for i, m in enumerate(messages):
            if m.get("id") == after_id:
                idx = i
                break
        messages = messages[idx + 1:] if idx is not None else []
        # after= is used by reconnect sync; no limit/before pagination applied in this branch
        pending_count = 0
        for s in session_mgr.sessions.values():
            if s.voice == voice_id and s.interjections:
                pending_count = len(s.interjections)
                break
        return JSONResponse(
            {"voice_id": voice_id, "messages": messages, "pending_interjections": pending_count},
            headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
        )
    # Pagination: before= cursor returns messages before that ID (for loading older pages)
    before_id = request.query_params.get("before")
    if before_id:
        idx = None
        for i, m in enumerate(messages):
            if m.get("id") == before_id:
                idx = i
                break
        # Return only entries before the cursor message
        messages = messages[:idx] if idx is not None else messages
    # limit= caps the number of returned messages (default 150, max 500)
    try:
        limit = min(int(request.query_params.get("limit", 150)), 500)
    except (ValueError, TypeError):
        limit = 150
    has_more = len(messages) > limit
    # Always return the last N (most recent end of the slice)
    messages = messages[-limit:] if has_more else messages
    # Include count of pending interjections so browser can style unseen messages
    pending_count = 0
    for s in session_mgr.sessions.values():
        if s.voice == voice_id and s.interjections:
            pending_count = len(s.interjections)
            break
    return JSONResponse(
        {"voice_id": voice_id, "messages": messages, "has_more": has_more, "pending_interjections": pending_count},
        headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
    )


@app.delete("/api/history/{voice_id}")
async def clear_history(voice_id: str, request: Request):
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    await asyncio.to_thread(history.clear, voice_id, prefix)
    return JSONResponse({"status": "cleared", "voice_id": voice_id})


@app.get("/api/search")
async def search_history(request: Request):
    """Search across all agent conversation histories."""
    q = request.query_params.get("q", "")
    if not q:
        return JSONResponse({"error": "missing 'q' parameter"}, status_code=400)
    agent = request.query_params.get("agent")
    voice_ids = [a.strip() for a in agent.split(",")] if agent else None
    role = request.query_params.get("role")
    roles = [r.strip() for r in role.split(",")] if role else None
    after_ts = float(request.query_params.get("after", 0)) or None
    before_ts = float(request.query_params.get("before", 0)) or None
    limit = min(int(request.query_params.get("limit", 50)), 200)
    context = min(int(request.query_params.get("context", 0)), 20)
    results = await asyncio.to_thread(
        history.search, q, voice_ids, roles, after_ts, before_ts, limit, context=context,
    )
    return JSONResponse({"query": q, "count": len(results), "results": results})


@app.post("/api/sessions/{session_id}/mark-read")
async def mark_session_read(session_id: str):
    """Mark a session's unread count as zero."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return JSONResponse({"error": "session not found"}, status_code=404)
    session.unread_count = 0
    return JSONResponse({"session_id": session_id, "unread_count": 0})


@app.post("/api/sessions/{session_id}/viewing")
async def set_viewing_session(session_id: str):
    """Tell the server which session the browser is currently viewing.
    The server won't increment unread for the viewed session."""
    global _browser_viewed_session
    _browser_viewed_session = session_id
    # Also clear unread for this session since the user is looking at it
    session = session_mgr.sessions.get(session_id)
    if session:
        session.unread_count = 0
    return JSONResponse({"viewing": session_id})


# ---------------------------------------------------------------------------
# Messaging API
# ---------------------------------------------------------------------------

def _resolve_session(name: str):
    """Resolve a friendly name (sky, alloy) or voice ID to a session."""
    for s in session_mgr.sessions.values():
        voice_name = s.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
        if (voice_name == name or s.voice == name or
                s.session_id == name or s.label.lower() == name.lower()):
            return s
    return None


@app.post("/api/messages/send")
async def send_message(request: Request):
    """Send a message from one agent to another via tmux injection."""
    data = await request.json()
    sender_id = data.get("sender")
    recipient_name = data.get("to")
    content = data.get("message", "")
    expect_response = data.get("expect_response", False)
    parent_id = data.get("parent_id", "")

    if not sender_id or not recipient_name or (not content and not parent_id):
        return JSONResponse({"error": "sender, to, and message are required (or use parent_id for bare ack)"}, status_code=400)

    sender = session_mgr.sessions.get(sender_id)
    if not sender:
        return JSONResponse({"error": f"sender session '{sender_id}' not found"}, status_code=404)

    recipient = _resolve_session(recipient_name)
    if not recipient:
        return JSONResponse({"error": f"recipient '{recipient_name}' not found"}, status_code=404)

    if not recipient.tmux_session:
        return JSONResponse({"error": f"recipient has no tmux session"}, status_code=400)

    sender_name = sender.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
    recip_name = recipient.voice.replace("af_", "").replace("am_", "").replace("bm_", "")

    # Send via broker (skip tmux injection for inter-agent messages)
    msg = await broker.send(
        sender=sender_id,
        recipient=recipient.session_id,
        content=content,
        recipient_tmux=recipient.tmux_session,
        sender_name=sender_name,
        recipient_name=recip_name,
        expect_response=expect_response,
        skip_tmux=True,
        parent_id=parent_id,
    )

    # Deliver via exactly ONE path to avoid duplicate delivery:
    # - In wait → inbox + wait queue push (immediate, agent sees it now)
    # - Not in wait → inbox (hooks deliver via additionalContext)
    is_bare_ack_msg = bool(parent_id and not content)
    inbox_msg = {
        "id": msg.id,
        "from": sender_name,
        "type": "ack" if is_bare_ack_msg else "agent",
        "content": content,
        "parent_id": parent_id,
    }
    if recipient.state == AgentState.IDLE and recipient.work_dir:
        await _inbox_write_and_notify(recipient, inbox_msg)
        log.info("[%s] Message %s injected via wait queue", recipient.session_id, msg.id)
    elif recipient.work_dir:
        await _inbox_write_and_notify(recipient, inbox_msg)
        log.info("[%s] Message %s written to inbox for hook delivery", recipient.session_id, msg.id)
    else:
        # Fallback — no inbox, not in wait, queue as interjection
        recipient.interjections.append(formatted)
        log.info("[%s] Message %s queued as interjection (fallback)", recipient.session_id, msg.id)

    # Save to history so messages persist across browser reloads
    is_bare_ack = bool(parent_id and not content)
    await asyncio.to_thread(history.append, recipient.voice, recipient.label, "system",
                   f"[Agent msg from {sender_name.capitalize()}] {content}",
                   _hist_prefix(recipient),
                   msg_id=msg.id, parent_id=parent_id or None, bare_ack=is_bare_ack)
    await asyncio.to_thread(history.append, sender.voice, sender.label, "system",
                   f"[Agent msg to {recip_name.capitalize()}] {content}",
                   _hist_prefix(sender),
                   msg_id=msg.id, parent_id=parent_id or None, bare_ack=is_bare_ack)

    # Notify browser about the message
    await send_to_browser({
        "type": "agent_message",
        "message": msg.to_dict(),
    })

    return JSONResponse({"id": msg.id, "state": msg.state})


@app.post("/api/notify/user")
async def notify_user(request: Request):
    """Send a visual notification to the browser (no TTS).
    Requires X-ClawMux-Token header. Used by external tools (cron, pollers, etc.)
    to display a toast/banner in the hub UI.

    Body: {"message": "...", "title": "...", "level": "info|warning|error"}
    """
    from hub_config import EXTERNAL_TOKEN
    token = request.headers.get("X-ClawMux-Token", "")
    if not token or token != EXTERNAL_TOKEN:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    data = await request.json()
    message = data.get("message", "").strip()
    title = data.get("title", "").strip()
    level = data.get("level", "info")
    if not message:
        return JSONResponse({"error": "message is required"}, status_code=400)

    await send_to_browser({
        "type": "user_notification",
        "message": message,
        "title": title,
        "level": level,
    })
    log.info("User notification sent: [%s] %s", level, message)
    return JSONResponse({"ok": True})


@app.post("/api/messages/external")
async def send_external_message(request: Request):
    """Accept a message from an authorized external system (e.g. OpenClaw).
    Requires X-ClawMux-Token header matching the hub's external_token."""
    from hub_config import EXTERNAL_TOKEN
    token = request.headers.get("X-ClawMux-Token", "")
    if not token or token != EXTERNAL_TOKEN:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    data = await request.json()
    sender_name = data.get("sender", "external").strip() or "external"
    recipient_name = data.get("to", "")
    content = data.get("message", "")
    parent_id = data.get("parent_id", "")

    if not recipient_name or (not content and not parent_id):
        return JSONResponse({"error": "to and message are required"}, status_code=400)

    recipient = _resolve_session(recipient_name)
    if not recipient:
        return JSONResponse({"error": f"recipient '{recipient_name}' not found"}, status_code=404)

    if not recipient.tmux_session:
        return JSONResponse({"error": "recipient has no tmux session"}, status_code=400)

    recip_name = recipient.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
    msg = await broker.send(
        sender=sender_name,
        recipient=recipient.session_id,
        content=content,
        recipient_tmux=recipient.tmux_session,
        sender_name=sender_name,
        recipient_name=recip_name,
        skip_tmux=True,
        parent_id=parent_id,
    )

    if recipient.state == AgentState.IDLE and recipient.work_dir:
        await _inbox_write_and_notify(recipient, {
            "id": msg.id,
            "from": sender_name,
            "type": "agent",
            "content": content,
        })
    elif recipient.work_dir:
        await _inbox_write_and_notify(recipient, {
            "id": msg.id,
            "from": sender_name,
            "type": "agent",
            "content": content,
        })

    await asyncio.to_thread(history.append, recipient.voice, recipient.label, "system",
                   f"[Agent msg from {sender_name.capitalize()}] {content}",
                   _hist_prefix(recipient),
                   msg_id=msg.id, parent_id=parent_id or None)

    await send_to_browser({"type": "agent_message", "message": msg.to_dict()})
    log.info("External message from '%s' to '%s': %s", sender_name, recipient.session_id, msg.id)
    return JSONResponse({"id": msg.id})


@app.post("/api/messages/external/outbound")
async def log_external_outbound(request: Request):
    """Log an outbound message from a ClawMux agent to an external system (e.g. OpenClaw).
    Requires X-ClawMux-Token header. Records in sender's history and broadcasts to browser."""
    from hub_config import EXTERNAL_TOKEN
    token = request.headers.get("X-ClawMux-Token", "")
    if not token or token != EXTERNAL_TOKEN:
        return JSONResponse({"error": "unauthorized"}, status_code=401)

    data = await request.json()
    sender_name = data.get("sender", "").strip()
    recipient_name = data.get("to", "external").strip() or "external"
    content = data.get("message", "")
    parent_id = data.get("parent_id", "")

    if not sender_name or not content:
        return JSONResponse({"error": "sender and message are required"}, status_code=400)

    sender = _resolve_session(sender_name)
    if not sender:
        return JSONResponse({"error": f"sender '{sender_name}' not found"}, status_code=404)

    msg_id = broker.generate_id(sender.session_id, recipient_name)
    import dataclasses
    from message_broker import Message, PENDING
    msg = Message(
        id=msg_id,
        sender=sender.session_id,
        recipient=recipient_name,
        content=content,
        sender_name=sender.label,
        recipient_name=recipient_name.capitalize(),
        parent_id=parent_id,
        created_at=time.time(),
    )
    broker.messages[msg_id] = msg

    await asyncio.to_thread(history.append, sender.voice, sender.label, "system",
                   f"[Agent msg to {recipient_name.capitalize()}] {content}",
                   _hist_prefix(sender),
                   msg_id=msg_id, parent_id=parent_id or None)

    await send_to_browser({"type": "agent_message", "message": msg.to_dict()})
    log.info("Outbound external message from '%s' to '%s': %s", sender.session_id, recipient_name, msg_id)
    return JSONResponse({"id": msg_id})


@app.post("/api/messages/image")
async def agent_post_image(request: Request, file: UploadFile):
    """Agent posts an image into the chat. Saves to shared uploads dir, renders inline."""
    sender_id = request.headers.get("X-ClawMux-Session-Id", "")
    sender = session_mgr.sessions.get(sender_id)
    if not sender:
        return JSONResponse({"error": f"sender session '{sender_id}' not found"}, status_code=404)

    contents = await file.read()
    if len(contents) > _MAX_UPLOAD_SIZE:
        return JSONResponse({"error": "file too large (50MB max)"}, status_code=413)

    _SHARED_UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    safe_name = Path(file.filename or "image.png").name
    unique_name = f"{_gen_msg_id()}-{safe_name}"
    (_SHARED_UPLOADS_DIR / unique_name).write_bytes(contents)

    msg_id = _gen_msg_id()
    url = f"/uploads/{unique_name}"
    markdown = f"![{safe_name}]({url})"

    await send_to_browser({
        "session_id": sender_id,
        "type": "assistant_text",
        "text": markdown,
        "msg_id": msg_id,
        "fire_and_forget": True,
    })
    await asyncio.to_thread(
        history.append, sender.voice, sender.label, "assistant",
        markdown, _hist_prefix(sender), msg_id=msg_id
    )
    log.info("[%s] Agent posted image: %s", sender_id, unique_name)
    return JSONResponse({"status": "ok", "url": url, "msg_id": msg_id})


@app.post("/api/messages/speak")
async def speak_to_user(request: Request):
    """Agent speaks to user via TTS — fire and forget."""
    data = await request.json()
    sender_id = data.get("sender", "")
    content = data.get("message", "")
    parent_id = data.get("parent_id", "")

    sender = session_mgr.sessions.get(sender_id)
    if not sender:
        return JSONResponse({"error": f"sender session '{sender_id}' not found"}, status_code=404)

    ack_only = data.get("ack_only", False)
    if ack_only and parent_id:
        # Bare ack — check if parent belongs to a group chat message
        group = await asyncio.to_thread(_find_group_for_message, parent_id)
        if group:
            # Route to group chat: only shows in browser group chat view, not delivered to other agents
            ack_id = _gen_msg_id()
            sender_label = sender.voice.replace("af_", "").replace("am_", "").replace("bm_", "").capitalize()
            await asyncio.to_thread(_append_group_history, group["id"], "user", "",
                                    sender=sender_label, msg_id=ack_id, parent_id=parent_id, bare_ack=True,
                                    sender_voice=sender.voice)
            await send_to_browser({
                "type": "groupchat_ack",
                "group_id": group["id"],
                "msg_id": parent_id,
                "ack_id": ack_id,
                "sender": sender_label,
                "sender_voice": sender.voice,
            })
            return {"id": ack_id, "status": "ack_sent"}
        # Regular session ack — thumbs up in agent's own chat
        msg_id = _gen_msg_id()
        sender_name = sender.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
        # Save to history so ack persists across reloads
        await asyncio.to_thread(history.append, sender.voice, sender.label, "assistant", "",
                       _hist_prefix(sender), msg_id=msg_id,
                       parent_id=parent_id, bare_ack=True)
        await send_to_browser({
            "type": "agent_message",
            "message": {
                "id": msg_id,
                "sender": sender_id,
                "sender_name": sender_name,
                "recipient": sender_id,  # show in sender's chat
                "recipient_name": "user",
                "content": "",
                "parent_id": parent_id,
                "bare_ack": True,
            },
        })
        return {"id": msg_id, "status": "ack_sent"}

    if not content:
        return JSONResponse({"error": "message is required"}, status_code=400)

    sender_name = sender.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
    msg_id = _gen_msg_id()

    if sender_id != _browser_viewed_session:
        sender.unread_count += 1

    # Send text to browser chat FIRST (fire_and_forget prevents auto-record trigger)
    await send_to_browser({"session_id": sender_id, "type": "assistant_text", "text": content, "msg_id": msg_id, "fire_and_forget": True})

    # Save to history (in thread to avoid blocking event loop)
    await asyncio.to_thread(history.append, sender.voice, sender.label, "assistant", content, _hist_prefix(sender), msg_id=msg_id)

    # TTS — strip non-speakable content and play
    settings = _load_settings()
    skip_tts = sender.text_mode or not settings.get("tts_enabled", True)
    if not skip_tts:
        tts_message = strip_non_speakable(content)
        if tts_message.strip():
            try:
                audio_b64, word_timestamps = await tts_captioned(tts_message, sender.voice, sender.speed)
            except Exception as e:
                log.warning("[%s] Captioned TTS failed (%s), falling back", sender_id, e)
                mp3 = await tts(tts_message, sender.voice, sender.speed)
                audio_b64 = base64.b64encode(mp3).decode()
                word_timestamps = []
            audio_msg = {"session_id": sender_id, "type": "audio", "data": audio_b64, "msg_id": msg_id}
            if word_timestamps:
                audio_msg["words"] = word_timestamps
            await send_to_browser(audio_msg)

    log.info("[%s] Spoke to user: %s", sender_id, content[:80])
    return JSONResponse({"id": msg_id, "state": "delivered"})


@app.post("/api/messages/{msg_id}/ack")
async def ack_message(msg_id: str):
    """Acknowledge receipt of a message."""
    if not broker.acknowledge(msg_id):
        return JSONResponse({"error": "message not found or already acknowledged"}, status_code=404)

    msg = broker.get_message(msg_id)
    await send_to_browser({
        "type": "agent_message",
        "message": msg.to_dict(),
    })

    return JSONResponse({"id": msg_id, "state": "acknowledged"})


@app.post("/api/messages/{msg_id}/reply")
async def reply_to_message(msg_id: str, request: Request):
    """Reply to a specific message."""
    data = await request.json()
    response_text = data.get("message", "")
    if not response_text:
        return JSONResponse({"error": "message is required"}, status_code=400)

    if not broker.reply(msg_id, response_text):
        return JSONResponse({"error": "message not found"}, status_code=404)

    msg = broker.get_message(msg_id)
    await send_to_browser({
        "type": "agent_message",
        "message": msg.to_dict(),
    })

    return JSONResponse({"id": msg_id, "state": "responded", "response": response_text})


@app.get("/api/messages")
async def list_messages(session_id: str = None):
    """List messages, optionally filtered by session."""
    if session_id:
        msgs = broker.get_messages_for(session_id)
        return JSONResponse([m.to_dict() for m in msgs])
    return JSONResponse(broker.list_all())


@app.get("/api/messages/{msg_id}")
async def get_message(msg_id: str):
    """Get a specific message by ID."""
    msg = broker.get_message(msg_id)
    if not msg:
        return JSONResponse({"error": "message not found"}, status_code=404)
    return JSONResponse(msg.to_dict())


# ---------------------------------------------------------------------------
# Inbox API
# ---------------------------------------------------------------------------

@app.get("/api/inbox/{session_id}")
async def get_inbox(session_id: str):
    """Read and clear all inbox messages for a session."""
    session = session_mgr.sessions.get(session_id)
    if not session or not session.work_dir:
        return JSONResponse({"messages": []})
    messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
    if messages:
        # Notify browser that inbox was cleared
        await send_to_browser({
            "type": "inbox_update",
            "session_id": session_id,
            "count": 0,
        })
    return JSONResponse({"messages": messages})


@app.get("/api/inbox/{session_id}/peek")
async def peek_inbox(session_id: str):
    """Check inbox without consuming messages."""
    session = session_mgr.sessions.get(session_id)
    if not session or not session.work_dir:
        return JSONResponse({"count": 0})
    count = await asyncio.to_thread(inbox.peek, session.work_dir)
    latest = await asyncio.to_thread(inbox.peek_latest, session.work_dir) if count > 0 else None
    result = {"count": count}
    if latest:
        result["latest"] = {
            "from": latest.get("from", ""),
            "type": latest.get("type", ""),
            "preview": latest.get("content", "")[:100],
        }
    return JSONResponse(result)


async def _inject_inbox(session, session_id: str) -> None:
    """Deliver pending inbox messages to an agent via tmux injection.

    Uses a per-session lock to serialize concurrent deliveries. When two messages
    arrive simultaneously (e.g. from concurrent group sends), the second task waits
    for the first to complete before acquiring the lock — preventing Enter from one
    injection firing mid-paste of another.
    """
    lock = _injection_locks.setdefault(session_id, asyncio.Lock())
    async with lock:
        messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
        if not messages:
            return

        lines = []
        has_user_msg = any(m.get("type") not in ("system", "ack") for m in messages)
        if session.walking_mode and has_user_msg:
            lines.append("[SYSTEM] Walking mode active — respond in plain spoken text only. No markdown, no underscores, no special formatting.")
        for msg in messages:
            msg_type = msg.get("type", "system")
            sender = msg.get("from", "unknown")
            content = msg.get("content", "")
            msg_id = msg.get("id", "")
            if msg_type == "agent":
                lines.append(f"[MSG id:{msg_id} from:{sender}] {content}")
            elif msg_type in ("voice", "text", "file_upload"):
                lines.append(f"[VOICE id:{msg_id} from:{sender}] {content}")
            elif msg_type == "group":
                group_name = msg.get("group_name", "group")
                lines.append(f"[GROUP:{group_name} id:{msg_id} from:{sender}] {content}")
            elif msg_type == "ack":
                parent_id = msg.get("parent_id", "")
                lines.append(f"[ACK from:{sender} on:{parent_id}]")
            else:
                lines.append(f"[SYSTEM] {content}")

        text = "\n".join(lines)
        try:
            await session_mgr.backend.deliver_message(session.tmux_session, text)
            log.info("[%s] Injected %d message(s) via tmux", session_id, len(messages))
            await send_to_browser({
                "type": "inbox_update",
                "session_id": session_id,
                "count": 0,
            })
        except Exception as exc:
            log.error("[%s] tmux injection FAILED: %s — %d message(s) returned to inbox",
                      session_id, exc, len(messages))
            for msg in messages:
                await asyncio.to_thread(inbox.write, session.work_dir, msg)


async def _inbox_write_and_notify(session, msg_dict: dict) -> dict:
    """Write to inbox and notify browser + wait WS."""
    written = await asyncio.to_thread(inbox.write, session.work_dir, msg_dict)
    count = await asyncio.to_thread(inbox.peek, session.work_dir)
    await send_to_browser({
        "type": "inbox_update",
        "session_id": session.session_id,
        "count": count,
        "latest": {
            "from": msg_dict.get("from", ""),
            "type": msg_dict.get("type", ""),
            "preview": msg_dict.get("content", "")[:100],
        },
    })
    # Inject immediately. The per-session lock in _inject_inbox serializes concurrent
    # deliveries — no cancel needed; a queued task will pick up the latest inbox contents.
    if session.work_dir:
        task = asyncio.create_task(_inject_inbox(session, session.session_id))
        _pending_injections[session.session_id] = task
    return written


# ---------------------------------------------------------------------------
# Audio API
# ---------------------------------------------------------------------------

# /api/transcribe, /api/tts, /api/tts-captioned → voice_router

async def _load_whisper_model(model_name: str) -> None:
    """Dynamically load a Whisper model via the server's /load endpoint."""
    model_path = os.path.join(hub_config.WHISPER_MODEL_DIR, f"ggml-{model_name}.bin")
    if not os.path.isfile(model_path):
        log.warning("Whisper model file not found: %s", model_path)
        return
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                f"{hub_config.WHISPER_URL}/load",
                files={"model": (None, model_path)},
            )
            if resp.status_code == 200:
                log.info("Whisper model loaded: %s", model_name)
            else:
                log.error("Whisper /load failed (%d): %s", resp.status_code, resp.text)
    except Exception as e:
        log.error("Whisper model load error: %s", e)


@app.get("/api/settings")
async def get_settings():
    return JSONResponse(_load_settings())


@app.put("/api/settings")
async def update_settings(request: Request):
    data = await request.json()
    settings = _load_settings()
    settings.update(data)
    # Apply model change at runtime
    if "model" in data and data["model"] in ("opus", "sonnet", "haiku"):
        hub_config.CLAUDE_MODEL = data["model"]
    if "effort" in data and data["effort"] in ("low", "medium", "high"):
        hub_config.CLAUDE_EFFORT = data["effort"]
    if "tts_url" in data and data["tts_url"]:
        hub_config.KOKORO_URL = data["tts_url"].rstrip("/")
        log.info("TTS URL changed to: %s", hub_config.KOKORO_URL)
    if "stt_url" in data and data["stt_url"]:
        hub_config.WHISPER_URL = data["stt_url"].rstrip("/")
        log.info("STT URL changed to: %s", hub_config.WHISPER_URL)
    if "quality_mode" in data and data["quality_mode"] in ("high", "medium", "low"):
        hub_config.QUALITY_MODE = data["quality_mode"]
        model_name = hub_config.QUALITY_MODEL_MAP.get(data["quality_mode"], "base")
        log.info("Quality mode changed to: %s (model: %s)", data["quality_mode"], model_name)
        # Dynamically load the Whisper model via /load endpoint
        asyncio.create_task(_load_whisper_model(model_name))
    _save_settings(settings)
    log.info("Settings updated: %s", data)
    return JSONResponse(settings)


def _load_settings() -> dict:
    settings_path = hub_config.DATA_DIR / "settings.json"
    defaults = {
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
        "tts_url": hub_config.KOKORO_URL,
        "stt_url": hub_config.WHISPER_URL,
        "quality_mode": "high",
    }
    if settings_path.exists():
        try:
            stored = json.loads(settings_path.read_text())
            defaults.update(stored)
        except Exception:
            pass
    return defaults


def _save_settings(settings: dict) -> None:
    settings_path = hub_config.DATA_DIR / "settings.json"
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2))



@app.get("/api/notes")
async def get_notes():
    notes_path = hub_config.DATA_DIR / "notes.json"
    if notes_path.exists():
        try:
            return JSONResponse(json.loads(notes_path.read_text()))
        except Exception:
            pass
    return JSONResponse({"now": "", "later": ""})


@app.put("/api/notes")
async def update_notes(request: Request):
    data = await request.json()
    notes = {"now": data.get("now", ""), "later": data.get("later", "")}
    notes_path = hub_config.DATA_DIR / "notes.json"
    notes_path.parent.mkdir(parents=True, exist_ok=True)
    notes_path.write_text(json.dumps(notes, indent=2))
    return JSONResponse(notes)




@app.get("/api/services/status")
async def services_status():
    tts_ok = False
    stt_ok = False
    async with httpx.AsyncClient(timeout=3) as client:
        try:
            await client.get(f"{hub_config.KOKORO_URL}/v1/audio/speech")
            tts_ok = True
        except Exception:
            pass
        try:
            await client.get(f"{hub_config.WHISPER_URL}/v1/audio/transcriptions")
            stt_ok = True
        except Exception:
            pass
    return JSONResponse({"tts": tts_ok, "stt": stt_ok})


_last_good_usage: dict | None = None
_USAGE_SIDECAR = hub_config.DATA_DIR / "usage-last-good.json"

def _load_usage_sidecar() -> dict | None:
    """Load last-known-good usage from sidecar file."""
    if _USAGE_SIDECAR.exists():
        try:
            return json.loads(_USAGE_SIDECAR.read_text())
        except Exception:
            pass
    return None

def _save_usage_sidecar(data: dict) -> None:
    """Persist last-known-good usage to sidecar file."""
    try:
        _USAGE_SIDECAR.parent.mkdir(parents=True, exist_ok=True)
        _USAGE_SIDECAR.write_text(json.dumps(data, indent=2))
    except Exception:
        pass

def _get_fallback_usage() -> dict | None:
    """Return in-memory cache or sidecar file data."""
    global _last_good_usage
    if _last_good_usage:
        return _last_good_usage
    _last_good_usage = _load_usage_sidecar()
    return _last_good_usage

@app.get("/api/usage")
async def get_usage():
    """Return Claude usage stats from local cache."""
    global _last_good_usage
    usage_path = Path.home() / ".claude" / "usage-cache.json"
    if not usage_path.exists():
        fallback = _get_fallback_usage()
        if fallback:
            return JSONResponse(fallback)
        return JSONResponse({"error": "No usage data"}, status_code=404)
    try:
        data = json.loads(usage_path.read_text())
        if "error" in data or "five_hour" not in data:
            fallback = _get_fallback_usage()
            if fallback:
                return JSONResponse(fallback)
            return JSONResponse({"error": "Usage data unavailable"}, status_code=503)
        _last_good_usage = data
        _save_usage_sidecar(data)
        return JSONResponse(data)
    except Exception as e:
        fallback = _get_fallback_usage()
        if fallback:
            return JSONResponse(fallback)
        return JSONResponse({"error": str(e)}, status_code=500)


@app.get("/api/context")
async def get_context():
    """Return cached context window usage for all active sessions."""
    # Clean out entries for sessions that no longer exist
    active = set(session_mgr.sessions.keys())
    return JSONResponse({sid: v for sid, v in _context_cache.items() if sid in active})


@app.get("/api/debug")
async def debug_info():
    import time as _time

    # System stats
    system = {}
    try:
        import psutil
        system["cpu_percent"] = psutil.cpu_percent(interval=0.1)
        mem = psutil.virtual_memory()
        system["ram_used_gb"] = round(mem.used / 1073741824, 1)
        system["ram_total_gb"] = round(mem.total / 1073741824, 1)
        system["ram_percent"] = mem.percent
    except ImportError:
        system["cpu_percent"] = None
        system["ram_percent"] = None

    # GPU stats via nvidia-smi
    try:
        gpu_proc = await asyncio.create_subprocess_exec(
            "nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        gpu_out, _ = await gpu_proc.communicate()
        if gpu_proc.returncode == 0:
            parts = gpu_out.decode().strip().split(", ")
            system["gpu_percent"] = int(parts[0])
            system["vram_used_mb"] = int(parts[1])
            system["vram_total_mb"] = int(parts[2])
            system["gpu_temp_c"] = int(parts[3])
    except Exception:
        pass

    # Gather tmux sessions
    tmux_sessions = []
    try:
        proc = await asyncio.create_subprocess_exec(
            "tmux", "list-sessions", "-F",
            "#{session_name}\t#{session_created}\t#{session_windows}\t#{session_attached}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await proc.communicate()
        if proc.returncode == 0:
            for line in stdout.decode().strip().splitlines():
                parts = line.split("\t")
                if len(parts) >= 4:
                    tmux_sessions.append({
                        "name": parts[0],
                        "created": int(parts[1]),
                        "windows": int(parts[2]),
                        "attached": int(parts[3]) > 0,
                        "is_voice": parts[0].startswith("voice-"),
                    })
    except Exception:
        pass

    # Check service connectivity
    services = {}
    async with httpx.AsyncClient(timeout=3) as client:
        for name, url in [("whisper", hub_config.WHISPER_URL), ("kokoro", hub_config.KOKORO_URL)]:
            try:
                resp = await client.get(url)
                services[name] = {"status": "up", "code": resp.status_code, "url": url}
            except Exception as e:
                services[name] = {"status": "down", "error": str(e), "url": url}

    # Hub sessions
    hub_sessions = []
    for sid, s in session_mgr.sessions.items():
        hub_sessions.append({
            **s.to_dict(),
            "work_dir": s.work_dir,
            "idle_seconds": round(_time.time() - s.last_activity),
            "age_seconds": round(_time.time() - s.created_at),
        })

    return JSONResponse({
        "hub": {
            "port": HUB_PORT,
            "uptime_seconds": round(_time.time() - HUB_START_TIME),
            "browser_connected": len(browser_clients) > 0,
            "client_count": len(browser_clients),
            "session_count": len(session_mgr.sessions),
        },
        "system": system,
        "sessions": hub_sessions,
        "tmux_sessions": tmux_sessions,
        "services": services,
        "messages": {
            "total": len(broker.messages),
            "pending": sum(1 for m in broker.messages.values() if m.state == "pending"),
            "acknowledged": sum(1 for m in broker.messages.values() if m.state == "acknowledged"),
            "responded": sum(1 for m in broker.messages.values() if m.state == "responded"),
            "failed": sum(1 for m in broker.messages.values() if m.state == "failed"),
        },
    })


@app.get("/api/debug/log")
async def debug_log():
    log_path = Path("/tmp/clawmux.log")
    lines = []
    try:
        if log_path.exists():
            text = log_path.read_text()
            lines = text.strip().splitlines()[-50:]
    except Exception:
        pass
    return JSONResponse({"lines": lines})


_uvicorn_server = None


def _log_sigterm(signum, frame):
    """Log SIGTERM and trigger uvicorn's graceful shutdown.

    IMPORTANT: Do NOT re-raise SIGTERM with SIG_DFL — that kills the process
    immediately without running the lifespan finally block.
    Instead, set uvicorn's should_exit flag for a clean shutdown.
    """
    my_pid = os.getpid()
    try:
        parent_pid = os.getppid()
        parent_info = subprocess.run(
            ["ps", "-p", str(parent_pid), "-o", "pid,ppid,cmd", "--no-headers"],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()
        log.warning("SIGTERM received! PID=%d parent=%s mode=%s", my_pid, parent_info or str(parent_pid), _shutdown_mode)
    except Exception as e:
        log.warning("SIGTERM received! PID=%d mode=%s (could not identify sender: %s)", my_pid, _shutdown_mode, e)
    # Tell uvicorn to shut down gracefully (runs lifespan finally block)
    if _uvicorn_server:
        _uvicorn_server.should_exit = True
    else:
        # Fallback: re-raise for uvicorn's default handler
        signal.signal(signum, signal.SIG_DFL)
        os.kill(my_pid, signum)


if __name__ == "__main__":
    _hub_host = os.environ.get("CLAWMUX_HOST", "127.0.0.1")
    config = uvicorn.Config(app, host=_hub_host, port=HUB_PORT, log_level="info")
    _uvicorn_server = uvicorn.Server(config)
    signal.signal(signal.SIGTERM, _log_sigterm)
    _uvicorn_server.run()
