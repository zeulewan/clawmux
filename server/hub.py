"""ClawMux — session launcher, TTS/STT engine, and WebSocket multiplexer.

Standalone FastAPI service that:
  - Spawns agent sessions via pluggable backends (Claude Code, OpenCode, Codex)
  - Handles TTS (Kokoro) and STT (Whisper) for all sessions
  - Multiplexes audio between browser and sessions via a single browser WS

Usage:
    python hub.py
"""

import asyncio
import os
import signal
import subprocess
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse

import hub_config
from hub_config import HUB_PORT
import inbox
from state_machine import AgentState
import voice
from voice import router as voice_router

from hub_state import (
    log, session_mgr, broker, history, agents_store,
    send_to_browser, _load_settings, _hist_prefix,
    _shutdown_mode, load_groups,
)
from monitors import (
    heartbeat_loop, state_monitor_loop, recovery_monitor_loop,
    context_poll_loop, usage_poll_loop,
    router as monitors_router,
)
from ws_handlers import router as ws_router
from routes import router as routes_router, _start_whisper_server, _stop_whisper_server


# ── ttyd monitors (cleaned up on shutdown) ────────────────────────────────────
# Stored in routes.py (_ttyd_monitors), imported for shutdown cleanup
from routes import _ttyd_monitors


# ── Lifespan ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Hub starting on port %d", HUB_PORT)
    saved = _load_settings()
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
    load_groups()
    await session_mgr.cleanup_stale_sessions()

    # Clear any text stuck in tmux input buffers from the previous hub run
    for session in list(session_mgr.sessions.values()):
        if session.tmux_session:
            backend = session_mgr._get_backend(session.backend)
            await backend.clear_stuck_buffer(session.tmux_session)

    # Flush pending interjections to inbox for delivery
    for session in list(session_mgr.sessions.values()):
        if session.interjections and session.work_dir:
            combined = " ... ".join(session.interjections)
            session.interjections.clear()
            await asyncio.to_thread(history.clear_interjections,
                                    session.voice, _hist_prefix(session))
            await asyncio.to_thread(inbox.write, session.work_dir, {
                "id": f"msg-{uuid.uuid4().hex[:8]}",
                "from": "user",
                "type": "voice",
                "content": combined,
            })
            session.set_state(AgentState.IDLE)
            log.info("[%s] Flushed interjection(s) to inbox on startup", session.session_id)

    # Kill orphaned ttyd processes from previous hub runs
    try:
        await asyncio.create_subprocess_exec(
            "pkill", "-f", "ttyd.*--port.*9[78][0-9][0-9]",
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except Exception:
        pass

    broker.start()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    hb_task = asyncio.create_task(heartbeat_loop())
    monitor_task = asyncio.create_task(state_monitor_loop())
    recovery_task = asyncio.create_task(recovery_monitor_loop())
    context_task = asyncio.create_task(context_poll_loop())
    usage_task = asyncio.create_task(usage_poll_loop())

    startup_settings = _load_settings()
    if not startup_settings.get("stt_enabled", True):
        asyncio.create_task(_stop_whisper_server())
    else:
        asyncio.create_task(_start_whisper_server())
    try:
        yield
    finally:
        broker.stop()
        timeout_task.cancel()
        hb_task.cancel()
        monitor_task.cancel()
        recovery_task.cancel()
        context_task.cancel()
        usage_task.cancel()

        # Kill all ttyd monitor processes
        for key, mon in list(_ttyd_monitors.items()):
            proc = mon.get("proc")
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
            port = mon.get("port")
            if port:
                try:
                    subprocess.run(
                        ["tailscale", "serve", f"--https={port}", "off"],
                        capture_output=True, timeout=3,
                    )
                except Exception:
                    pass
        _ttyd_monitors.clear()

        import hub_state
        if hub_state._shutdown_mode == "reload":
            log.info("Hub reloading — keeping tmux sessions alive for re-adoption")
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


# ── App setup ─────────────────────────────────────────────────────────────────

app = FastAPI(lifespan=lifespan)
app.include_router(voice_router)
app.include_router(monitors_router)
app.include_router(ws_router)
app.include_router(routes_router)

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


# ── Main ──────────────────────────────────────────────────────────────────────

_uvicorn_server = None


def _log_sigterm(signum, frame):
    """Log SIGTERM and trigger uvicorn's graceful shutdown."""
    import hub_state
    my_pid = os.getpid()
    try:
        parent_pid = os.getppid()
        parent_info = subprocess.run(
            ["ps", "-p", str(parent_pid), "-o", "pid,ppid,cmd", "--no-headers"],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()
        log.warning("SIGTERM received! PID=%d parent=%s mode=%s", my_pid, parent_info or str(parent_pid), hub_state._shutdown_mode)
    except Exception as e:
        log.warning("SIGTERM received! PID=%d mode=%s (could not identify sender: %s)", my_pid, hub_state._shutdown_mode, e)
    if _uvicorn_server:
        _uvicorn_server.should_exit = True
    else:
        signal.signal(signum, signal.SIG_DFL)
        os.kill(my_pid, signum)


if __name__ == "__main__":
    _hub_host = os.environ.get("CLAWMUX_HOST", "127.0.0.1")
    config = uvicorn.Config(app, host=_hub_host, port=HUB_PORT, log_level="info")
    _uvicorn_server = uvicorn.Server(config)
    signal.signal(signal.SIGTERM, _log_sigterm)
    _uvicorn_server.run()
