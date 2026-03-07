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

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stderr),
        logging.FileHandler("/tmp/clawmux.log", mode="a"),
    ],
)
log = logging.getLogger("hub")

history = HistoryStore()
project_mgr = ProjectManager()
agents_store = AgentsStore()
session_mgr = SessionManager(history_store=history, project_mgr=project_mgr, agents_store=agents_store)
broker = MessageBroker()


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
_QUEUEABLE_TYPES = {"assistant_text", "user_text", "audio", "done", "session_status", "session_ended"}
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
    for ws in list(browser_clients):
        try:
            await ws.send_json(data)
        except Exception:
            dead.append(ws)
    for ws in dead:
        browser_clients.discard(ws)
        if msg_type in ("assistant_text", "user_text", "audio"):
            log.warning("[%s] Browser client died during %s send", session_id, msg_type)
    return len(browser_clients) > 0


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


async def compaction_monitor_loop() -> None:
    """Poll tmux panes for compaction status when context usage is high (>=80%)."""
    while True:
        await asyncio.sleep(3)
        for session_id in list(session_mgr.sessions):
            session = session_mgr.sessions.get(session_id)
            if not session or session.state == AgentState.DEAD:
                continue
            # Only check when context usage is >= 80% (use cached data)
            usage = _context_cache.get(session_id)
            if not usage or usage["percent"] < 80:
                if session.state == AgentState.COMPACTING:
                    # Context dropped below 80% (post-compaction reset)
                    session.set_state(AgentState.PROCESSING)
                    await send_to_browser({
                        "type": "compaction_status",
                        "session_id": session_id,
                        "compacting": False,
                    })
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
from voice import router as voice_router, tts, tts_captioned, stt, strip_non_speakable


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
_USAGE_POLL_INTERVAL = 300  # 5 minutes
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
    """Poll Anthropic usage API every 5 minutes, update cache + sidecar."""
    global _last_good_usage
    await asyncio.sleep(5)  # initial delay to let hub finish starting
    while True:
        data = await _fetch_usage_from_api()
        if data:
            _last_good_usage = data
            try:
                _USAGE_CACHE_PATH.write_text(json.dumps(data, indent=2))
            except Exception:
                pass
            _save_usage_sidecar(data)
            log.debug("Usage cache refreshed (5h: %.0f%%, 7d: %.0f%%)",
                      data.get("five_hour", {}).get("utilization", 0),
                      data.get("seven_day", {}).get("utilization", 0))
        await asyncio.sleep(_USAGE_POLL_INTERVAL)


# --- FastAPI app ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Hub starting on port %d", HUB_PORT)
    # Restore saved settings
    saved = _load_settings()
    import hub_config
    hub_config.CLAUDE_MODEL = saved.get("model", "opus")
    if saved.get("deployment_mode") in ("local", "split", "remote"):
        hub_config.DEPLOYMENT_MODE = saved["deployment_mode"]
    if saved.get("tts_url"):
        hub_config.KOKORO_URL = saved["tts_url"].rstrip("/")
    if saved.get("stt_url"):
        hub_config.WHISPER_URL = saved["stt_url"].rstrip("/")
    if saved.get("quality_mode") in ("high", "medium", "low"):
        hub_config.QUALITY_MODE = saved["quality_mode"]
    log.info("Model: %s, Mode: %s, TTS: %s, STT: %s",
             hub_config.CLAUDE_MODEL, hub_config.DEPLOYMENT_MODE,
             hub_config.KOKORO_URL, hub_config.WHISPER_URL)
    await agents_store.load()
    await session_mgr.cleanup_stale_sessions()
    broker.start()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    hb_task = asyncio.create_task(heartbeat_loop())
    compaction_task = asyncio.create_task(compaction_monitor_loop())
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
                    "from": "user",
                    "type": "voice",
                    "content": text,
                    "msg_id": umid,
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
                    "from": "user",
                    "type": "text",
                    "content": text,
                    "msg_id": umid,
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
                    "from": "user",
                    "type": "voice",
                    "content": combined,
                    "msg_id": umid,
                })
            elif session.work_dir:
                # Agent not in wait — write to inbox for hook-based delivery
                # (PostToolUse/PreToolUse will pick it up via additionalContext)
                await _inbox_write_and_notify(session, {
                    "from": "user",
                    "type": "voice",
                    "content": text,
                    "msg_id": umid,
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
    session.status_text = "Waiting"
    session.set_state(AgentState.IDLE)
    await _save_activity(session, "Waiting")

    # Tell browser agent is idle (so voice input isn't treated as interjection)
    await send_to_browser({"session_id": session_id, "type": "listening", "state": "idle"})
    await send_to_browser({
        "type": "session_status",
        "session_id": session_id,
        "state": session.state.value,
        "status_text": session.status_text,
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
        session.status_text = "Processing..."
        session.set_state(AgentState.PROCESSING)
        await _save_activity(session, "Processing")
        await send_to_browser({
            "type": "session_status",
            "session_id": session_id,
            "state": session.state.value,
            "status_text": session.status_text,
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
    session.project = data.get("project", "")
    session.project_area = data.get("area", "")
    log.info("[%s] Project status: %s / %s", session_id, session.project, session.project_area)
    await send_to_browser({
        "type": "project_status",
        "session_id": session_id,
        "project": session.project,
        "area": session.project_area,
    })
    # Persist to disk so it survives hub restarts
    if session.work_dir:
        try:
            Path(session.work_dir, ".project_status.json").write_text(
                json.dumps({"project": session.project, "area": session.project_area})
            )
        except Exception as e:
            log.warning("[%s] Failed to persist project status: %s", session_id, e)
    # Dual-write: update agents.json with project info
    await session_mgr._sync_agent_store(session.voice, session)
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


# --- Claude Code Hook Endpoint ---

def _session_from_cwd(cwd: str) -> "SessionInfo | None":
    """Map a working directory path to its ClawMux session.

    Claude Code hooks send the agent's cwd (e.g. /tmp/clawmux-sessions/clawmux/am_echo).
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


def _tool_status_text(tool_name: str, tool_input: dict) -> str:
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
        cmd = tool_input.get("command", "")
        desc = tool_input.get("description", "")
        preview = desc or cmd
        if len(preview) > 40:
            preview = preview[:37] + "..."
        return f"Running {preview}" if preview else "Running command"
    if tool_name == "Grep":
        pattern = tool_input.get("pattern", "")
        return f"Searching for {pattern[:30]}" if pattern else "Searching"
    if tool_name == "WebFetch":
        url = tool_input.get("url", "")
        try:
            from urllib.parse import urlparse
            domain = urlparse(url).netloc
            return f"Fetching {domain}" if domain else "Fetching URL"
        except Exception:
            return "Fetching URL"
    return _TOOL_STATUS_MAP.get(tool_name, tool_name)


def _format_inbox_messages(messages: list[dict]) -> str:
    """Format inbox messages as text for Claude's additionalContext."""
    lines = [f"You have {len(messages)} new message(s):"]
    for msg in messages:
        msg_type = msg.get("type", "system")
        sender = msg.get("from", "unknown")
        content = msg.get("content", "")
        msg_id = msg.get("msg_id") or msg.get("id", "")
        if msg_type == "agent":
            lines.append(f"[MSG id:{msg_id} from:{sender}] {content}")
        elif msg_type == "voice":
            lines.append(f"[VOICE id:{msg_id} from:{sender}] {content}")
        else:
            lines.append(f"[SYSTEM] {content}")
    return "\n".join(lines)


@app.post("/api/hooks/tool-status")
async def hook_tool_status(request: Request):
    """Receive Claude Code PreToolUse/PostToolUse hooks to update live session status."""
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({})

    event = data.get("hook_event_name", "")

    # Prefer X-ClawMux-Session header (set via CLAWMUX_SESSION_ID env var),
    # fall back to cwd-based lookup
    clawmux_sid = request.headers.get("x-clawmux-session", "")
    session = session_mgr.sessions.get(clawmux_sid) if clawmux_sid else None
    if not session:
        cwd = data.get("cwd", "")
        session = _session_from_cwd(cwd)
    if not session:
        return JSONResponse({})

    response_json = {}

    if event in ("PostToolUse", "PostToolUseFailure"):
        # Skip status_text updates while IDLE — wait WS is the sole authority
        if session.state == AgentState.IDLE:
            return JSONResponse(response_json)
        # Skip entirely for clawmux wait — wait WS handles all state transitions
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        if tool_name == "Bash" and "clawmux wait" in tool_input.get("command", ""):
            return JSONResponse(response_json)
        session.status_text = "Processing..."
        # Check inbox for pending messages — deliver via additionalContext
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                formatted = _format_inbox_messages(messages)
                response_json = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": formatted,
                    }
                }
                # Notify browser that inbox was cleared
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session.session_id,
                    "count": 0,
                })
    elif event == "Stop":
        # State does NOT change here — PROCESSING → IDLE only when wait WS connects
        pass
    elif event == "PreToolUse":
        # Skip status_text updates while IDLE — wait WS is the sole authority
        if session.state == AgentState.IDLE:
            return JSONResponse(response_json)
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        session.status_text = _tool_status_text(tool_name, tool_input)
        # Log beginning of tool use
        await _save_activity(session, session.status_text)
        # Catch end of compaction — first tool call after PreCompact
        if session.state == AgentState.COMPACTING:
            session.set_state(AgentState.PROCESSING)
        # Check inbox for urgent messages — deliver via additionalContext
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                formatted = _format_inbox_messages(messages)
                response_json = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": formatted,
                    }
                }
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session.session_id,
                    "count": 0,
                })
    elif event == "Notification":
        # Notification hook — relay to browser and check inbox
        notification = data.get("notification", {})
        await send_to_browser({
            "type": "notification",
            "session_id": session.session_id,
            "notification": notification,
        })
        # Also deliver any pending inbox messages
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                formatted = _format_inbox_messages(messages)
                response_json = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": formatted,
                    }
                }
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session.session_id,
                    "count": 0,
                })
    elif event == "SessionStart":
        # SessionStart hook — agent stays STARTING until first wait WS connects
        session.status_text = "Starting session..."
        await _save_activity(session, "Starting")
        if session.work_dir:
            messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
            if messages:
                formatted = _format_inbox_messages(messages)
                response_json = {
                    "hookSpecificOutput": {
                        "hookEventName": event,
                        "additionalContext": formatted,
                    }
                }
                await send_to_browser({
                    "type": "inbox_update",
                    "session_id": session.session_id,
                    "count": 0,
                })
    elif event == "PreCompact":
        session.set_state(AgentState.COMPACTING)
        session.status_text = "Compacting context..."
        await _save_activity(session, "Compacting")
    else:
        return JSONResponse({})

    # PostToolUse doesn't broadcast — "Processing..." is transient; the next
    # PreToolUse or wait WS connect will broadcast the real state.
    if event not in ("PostToolUse", "PostToolUseFailure"):
        msg = {
            "type": "session_status",
            "session_id": session.session_id,
            "state": session.state.value,
            "status_text": session.status_text,
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
        project = body.get("project")
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
        "from": "user",
        "type": "file_upload",
        "content": f"User uploaded a file: uploads/{safe_name}",
        "msg_id": umid,
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
    fields = {k: body[k] for k in ("project", "role", "area") if k in body}
    if not fields:
        return JSONResponse({"error": "No assignment fields provided"}, status_code=400)
    updated = await agents_store.update(voice_id, **fields)
    if updated is None:
        return JSONResponse({"error": "Agent not found"}, status_code=404)
    log.info("[agents] Assigned %s → project=%s role=%s area=%s",
             voice_id, updated.project, updated.role, updated.area)
    return JSONResponse(updated.to_dict())


# --- Project Management ---

@app.get("/api/projects")
async def list_projects():
    """Return projects in {projects: {slug: {...}}, active_project: slug} format."""
    projects_dict = {}
    for p in project_mgr.list_projects():
        slug = p.pop("slug")
        p.pop("active", None)
        projects_dict[slug] = p
    return JSONResponse({
        "projects": projects_dict,
        "active_project": project_mgr.active_project,
    })


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
    data = await request.json()
    new_name = data.get("name", "").strip()
    if not new_name:
        return JSONResponse({"error": "name is required"}, status_code=400)
    try:
        result = project_mgr.rename_project(slug, new_name)
        await send_to_browser({"type": "project_renamed", "slug": slug, "name": new_name})
        return JSONResponse(result)
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=404)


@app.delete("/api/projects/{slug}")
async def delete_project(slug: str):
    try:
        # Terminate sessions belonging to this project first
        to_terminate = [
            sid for sid, s in session_mgr.sessions.items()
            if s.project_slug == slug
        ]
        for sid in to_terminate:
            await session_mgr.terminate_session(sid)
        was_active = project_mgr.active_project == slug
        project_mgr.delete_project(slug)
        # Notify browser so sidebar/header refresh immediately
        await send_to_browser({"type": "project_deleted", "slug": slug})
        if was_active:
            await send_to_browser({"type": "project_switched", "project": project_mgr.active_project})
        return JSONResponse({"status": "deleted", "slug": slug, "terminated_sessions": len(to_terminate)})
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)


@app.get("/api/history/{voice_id}")
async def get_history(voice_id: str, request: Request):
    # Use project from query param or active project
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    messages = await asyncio.to_thread(history.load, voice_id, prefix)
    # Include count of pending interjections so browser can style unseen messages
    pending_count = 0
    for s in session_mgr.sessions.values():
        if s.voice == voice_id and s.interjections:
            pending_count = len(s.interjections)
            break
    return JSONResponse(
        {"voice_id": voice_id, "messages": messages, "pending_interjections": pending_count},
        headers={"Cache-Control": "no-cache, no-store, must-revalidate"},
    )


@app.delete("/api/history/{voice_id}")
async def clear_history(voice_id: str, request: Request):
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    await asyncio.to_thread(history.clear, voice_id, prefix)
    return JSONResponse({"status": "cleared", "voice_id": voice_id})


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
    if recipient.state == AgentState.IDLE and recipient.work_dir:
        # Wait mode — push via inbox + wait queue for immediate delivery
        await _inbox_write_and_notify(recipient, {
            "id": msg.id,
            "from": sender_name,
            "type": "agent",
            "content": content,
        })
        log.info("[%s] Message %s injected via wait queue", recipient.session_id, msg.id)
    elif recipient.work_dir:
        # Inbox — hook-based delivery (PostToolUse/PreToolUse additionalContext)
        await _inbox_write_and_notify(recipient, {
            "id": msg.id,
            "from": sender_name,
            "type": "agent",
            "content": content,
        })
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
        # Bare ack — just send thumbs up to browser, no TTS
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
    skip_tts = sender.text_mode or settings.get("text_only", False) or not settings.get("voice_responses", True)
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
            audio_msg = {"session_id": sender_id, "type": "audio", "data": audio_b64}
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
    # Push to wait WS only if agent is IDLE (in wait mode).
    # When not IDLE, hooks will deliver from the inbox file — pushing to
    # the queue too would cause duplicate delivery.
    if session.state == AgentState.IDLE and hasattr(session, "_wait_queue"):
        try:
            session._wait_queue.put_nowait(written)
        except Exception:
            pass
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
    # Apply deployment mode settings at runtime (hot-reload, no restart needed)
    if "deployment_mode" in data and data["deployment_mode"] in ("local", "split", "remote"):
        hub_config.DEPLOYMENT_MODE = data["deployment_mode"]
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
    settings_path = Path("data/settings.json")
    defaults = {
        "model": "opus",
        "auto_record": False,
        "auto_end": True,
        "auto_interrupt": False,
        "thinking_sounds": True,
        "audio_cues": True,
        "voice_responses": True,
        "silent_startup": False,
        "deployment_mode": "local",
        "tts_url": hub_config.KOKORO_URL,
        "stt_url": hub_config.WHISPER_URL,
        "quality_mode": "high",
        "text_only": False,
    }
    if settings_path.exists():
        try:
            stored = json.loads(settings_path.read_text())
            defaults.update(stored)
        except Exception:
            pass
    return defaults


def _save_settings(settings: dict) -> None:
    settings_path = Path("data/settings.json")
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2))



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
_USAGE_SIDECAR = Path("data/usage-last-good.json")

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
    config = uvicorn.Config(app, host="127.0.0.1", port=HUB_PORT, log_level="info")
    _uvicorn_server = uvicorn.Server(config)
    signal.signal(signal.SIGTERM, _log_sigterm)
    _uvicorn_server.run()
