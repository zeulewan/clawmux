"""Voice Chat Hub — session launcher, TTS/STT engine, and WebSocket multiplexer.

Standalone FastAPI service that:
  - Spawns Claude Code sessions in tmux
  - Accepts MCP server connections from each session (WS /mcp/{session_id})
  - Handles TTS (Kokoro) and STT (Whisper) for all sessions
  - Multiplexes audio between browser and sessions via a single browser WS

Usage:
    python hub.py
"""

import asyncio
import base64
import json
import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse

from history_store import HistoryStore
from hub_config import HUB_PORT, HUB_START_TIME, KOKORO_URL, WHISPER_URL
from session_manager import SessionManager

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stderr),
        logging.FileHandler("/tmp/voice-chat-hub.log", mode="a"),
    ],
)
log = logging.getLogger("hub")

history = HistoryStore()
session_mgr = SessionManager(history_store=history)

# Browser WebSocket clients (multiple connections supported)
browser_clients: set[WebSocket] = set()


async def send_to_browser(data: dict) -> bool:
    """Broadcast a message to all connected browser/app clients.
    Returns True if at least one client received the message."""
    dead = []
    for ws in list(browser_clients):
        try:
            await ws.send_json(data)
        except Exception:
            dead.append(ws)
    for ws in dead:
        browser_clients.discard(ws)
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


# --- TTS / STT ---

async def tts(text: str, voice: str = "af_sky", speed: float = 1.0) -> bytes:
    """Text → MP3 bytes via Kokoro."""
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{KOKORO_URL}/v1/audio/speech",
            json={"model": "tts-1", "input": text, "voice": voice, "response_format": "mp3", "speed": speed},
        )
        resp.raise_for_status()
    return resp.content


async def stt(audio_bytes: bytes) -> str:
    """Audio bytes → text via Whisper."""
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{WHISPER_URL}/v1/audio/transcriptions",
            files={"file": ("recording.webm", audio_bytes, "audio/webm")},
            data={"model": "whisper-1", "response_format": "json"},
        )
        resp.raise_for_status()
    return resp.json().get("text", "").strip()


# --- Converse logic (called by MCP sessions via WS) ---

async def handle_converse(session_id: str, message: str, wait_for_response: bool, voice: str, goodbye: bool = False) -> str:
    """Full converse flow: TTS → browser → record → STT → return text."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return "Error: Session not found."

    session.touch()

    # Use session's voice/speed overrides
    voice = session.voice
    speed = session.speed

    session.processing = False  # Agent is now in a converse cycle
    session.in_converse = True

    try:
        return await _do_converse(session_id, session, message, wait_for_response, voice, speed, goodbye)
    finally:
        session.in_converse = False


async def _do_converse(session_id, session, message, wait_for_response, voice, speed, goodbye):
    # Check for interjections BEFORE speaking — let agent see them first
    if session.interjections:
        text = " ... ".join(session.interjections)
        session.interjections.clear()
        history.clear_interjections(session.voice)
        log.info("[%s] Pre-speech interjection(s), skipping TTS: %s", session_id, text[:100])
        # Still show the assistant message in browser (but don't speak it)
        await send_to_browser({"session_id": session_id, "type": "assistant_text", "text": message})
        history.append(session.voice, session.label, "assistant", message)
        session.status_text = ""
        session.processing = True  # Agent will process the interjection
        await send_to_browser({"session_id": session_id, "type": "done", "processing": True})
        session.touch()
        return text

    # Signal that Claude is about to speak (lets client show thinking indicator)
    await send_to_browser({"session_id": session_id, "type": "thinking"})

    # Send assistant text to browser for chat display
    await send_to_browser({"session_id": session_id, "type": "assistant_text", "text": message})
    history.append(session.voice, session.label, "assistant", message)

    if session.text_mode:
        # Text mode: skip TTS entirely, go straight to listen phase
        log.info("[%s] Text mode, skipping TTS: %s", session_id, message[:80])
        if not wait_for_response:
            session.status_text = ""
            session.processing = not goodbye
            await send_to_browser({"session_id": session_id, "type": "done", "processing": not goodbye})
            if goodbye:
                await send_to_browser({"session_id": session_id, "type": "session_ended"})
            return "Message delivered."
        early_audio = None
    else:
        session.status_text = "Speaking..."
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Speaking..."})

        # TTS
        log.info("[%s] TTS: %s", session_id, message[:80])
        mp3 = await tts(message, voice, speed)
        audio_b64 = base64.b64encode(mp3).decode()

        # Send audio to browser
        session.playback_done.clear()
        has_clients = await send_to_browser({"session_id": session_id, "type": "audio", "data": audio_b64})

        if not has_clients:
            # No clients received the audio — no one will send playback_done
            log.warning("[%s] No clients connected, skipping playback wait", session_id)
            session.playback_done.set()

        if not wait_for_response:
            session.status_text = ""
            session.processing = not goodbye
            await send_to_browser({"session_id": session_id, "type": "done", "processing": not goodbye})
            if goodbye:
                await send_to_browser({"session_id": session_id, "type": "session_ended"})
            return "Message delivered."

        # Wait for playback_done OR user audio (user interrupting/switching devices)
        log.info("[%s] Waiting for playback_done", session_id)
        early_audio = None
        while not session.playback_done.is_set():
            # Check if audio arrived (user spoke before playback finished)
            if not session.audio_queue.empty():
                early_audio = session.audio_queue.get_nowait()
                if early_audio and len(early_audio) > 0:
                    log.info("[%s] Audio arrived during playback wait (%d bytes), skipping playback_done", session_id, len(early_audio))
                    break
                early_audio = None  # empty audio, keep waiting
            await asyncio.sleep(0.2)

    # Check for interjections (user spoke/typed while agent was busy)
    if session.interjections:
        text = " ... ".join(session.interjections)
        session.interjections.clear()
        history.clear_interjections(session.voice)
        log.info("[%s] Returning %d interjection(s): %s", session_id, text.count("...")+1, text[:100])
        session.status_text = ""
        session.processing = True  # Agent will process the interjection
        await send_to_browser({"session_id": session_id, "type": "done", "processing": True})
        session.touch()
        return text

    # Retry loop: wait for a client to connect and send real audio
    while True:
        # If we got early audio from the playback wait, use it
        if early_audio and len(early_audio) > 0:
            audio_bytes = early_audio
            early_audio = None
            break

        # Drain stale audio (but preserve text input markers)
        while not session.audio_queue.empty():
            try:
                item = session.audio_queue.get_nowait()
                if item == b"__text__":
                    # Put it back — this is a typed response, not stale audio
                    await session.audio_queue.put(item)
                    break
            except asyncio.QueueEmpty:
                break

        # Wait for at least one client to be connected
        logged_once = False
        while not browser_clients:
            if not logged_once:
                log.info("[%s] No clients, waiting for reconnect...", session_id)
                logged_once = True
            session.status_text = "Waiting for client..."
            await asyncio.sleep(2)

        # Tell browser to start recording
        session.status_text = "Listening..."
        await send_to_browser({"session_id": session_id, "type": "listening"})
        log.info("[%s] Listening...", session_id)

        # Wait for recorded audio (re-send listening every 5s in case client reconnected)
        while True:
            try:
                audio_bytes = await asyncio.wait_for(session.audio_queue.get(), timeout=5)
                break
            except asyncio.TimeoutError:
                # Re-send listening to any newly connected clients
                if browser_clients:
                    await send_to_browser({"session_id": session_id, "type": "listening"})
                else:
                    # All clients gone — push back to outer reconnect loop
                    audio_bytes = b""
                    break

        log.info("[%s] Got audio: %d bytes", session_id, len(audio_bytes))

        # Empty audio = session muted or client disconnected — retry
        if len(audio_bytes) == 0:
            log.info("[%s] Empty audio (muted/disconnect), retrying listen", session_id)
            continue

        break  # Got real audio

    # Text override (typed input from client) or STT
    if audio_bytes == b"__text__" and session.text_override:
        text = session.text_override
        session.text_override = ""
        log.info("[%s] Text input: %s", session_id, text[:100])
    else:
        session.status_text = "Transcribing..."
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
        text = await stt(audio_bytes)
        log.info("[%s] STT: %s", session_id, text[:100])

    # Send user's transcribed text to browser for chat display
    if text:
        await send_to_browser({"session_id": session_id, "type": "user_text", "text": text})
        history.append(session.voice, session.label, "user", text)

    session.status_text = ""
    session.processing = bool(text)  # Agent will process the user's response
    await send_to_browser({"session_id": session_id, "type": "done", "processing": bool(text)})

    session.touch()
    return text if text else "(no speech detected)"


# --- FastAPI app ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Hub starting on port %d", HUB_PORT)
    # Restore saved settings
    saved = _load_settings()
    import hub_config
    hub_config.CLAUDE_MODEL = saved.get("model", "opus")
    log.info("Model: %s", hub_config.CLAUDE_MODEL)
    await session_mgr.cleanup_stale_sessions()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    hb_task = asyncio.create_task(heartbeat_loop())
    try:
        yield
    finally:
        log.info("Hub shutting down, terminating all sessions")
        timeout_task.cancel()
        hb_task.cancel()
        for sid in list(session_mgr.sessions):
            try:
                await session_mgr.terminate_session(sid)
            except Exception:
                pass


app = FastAPI(lifespan=lifespan)
STATIC_DIR = Path(__file__).parent / "static"


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
        return FileResponse(path)
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
            # No clients left — unblock any waiting converse() calls
            for session in session_mgr.sessions.values():
                if session.playback_done:
                    session.playback_done.set()
                if session.audio_queue:
                    await session.audio_queue.put(b"")  # unblock audio_queue.get()


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
        audio_bytes = base64.b64decode(data["data"])
        log.info("[%s] Audio from browser: %d bytes", session_id, len(audio_bytes))
        await session.audio_queue.put(audio_bytes)

    elif msg_type == "text":
        text = data.get("text", "").strip()
        if text:
            log.info("[%s] Text from browser: %s", session_id, text[:100])
            session.text_override = text
            await session.audio_queue.put(b"__text__")

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
            history.save_interjections(session.voice, session.interjections)
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "interjection": True})
            history.append(session.voice, session.label, "user", text)

            # If agent is in an active converse call waiting for audio, inject
            # the interjection as audio queue input so it gets picked up immediately
            if session.in_converse:
                log.info("[%s] Agent in converse, injecting interjection via audio queue", session_id)
                session.text_override = " ... ".join(session.interjections)
                session.interjections.clear()
                history.clear_interjections(session.voice)
                await session.audio_queue.put(b"__text__")

    elif msg_type == "set_mode":
        mode = data.get("mode", "voice")
        session.text_mode = (mode == "text")
        log.info("[%s] Mode set to %s", session_id, mode)


# --- MCP Server WebSocket (one per session) ---

@app.websocket("/mcp/{session_id}")
async def mcp_websocket(ws: WebSocket, session_id: str):
    """WebSocket endpoint for hub_mcp_server.py instances to connect to."""
    await ws.accept()
    log.info("[%s] MCP server connected", session_id)

    session = session_mgr.sessions.get(session_id)
    if not session:
        log.error("[%s] MCP connected but session not found", session_id)
        await ws.close(code=4004, reason="Session not found")
        return

    was_already_ready = session.status == "ready" and session.mcp_ws is None
    session.mcp_ws = ws

    # Notify browser (skip noisy notification on reconnect after hub restart)
    if not was_already_ready:
        await send_to_browser({
            "type": "session_status",
            "session_id": session_id,
            "status": "ready",
        })
    else:
        # Silent reconnect — just update mcp_connected flag in browser
        await send_to_browser({
            "type": "session_status",
            "session_id": session_id,
            "status": "ready",
            "silent": True,
        })

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type")

            if msg_type == "converse":
                # Run converse and send result back
                try:
                    result = await handle_converse(
                        session_id=session_id,
                        message=data["message"],
                        wait_for_response=data.get("wait_for_response", True),
                        voice=data.get("voice", "af_sky"),
                        goodbye=data.get("goodbye", False),
                    )
                except Exception as e:
                    result = f"Error: {e}"
                    log.error("[%s] converse error: %s", session_id, e)

                await ws.send_json({"type": "converse_result", "text": result})

            elif msg_type == "set_project_status":
                if session:
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

            elif msg_type == "status_check":
                await ws.send_json({
                    "type": "status_result",
                    "connected": len(browser_clients) > 0,
                })

    except WebSocketDisconnect:
        log.info("[%s] MCP server disconnected", session_id)
    except Exception as e:
        log.error("[%s] MCP WS error: %s: %s", session_id, type(e).__name__, e)
    finally:
        if session and session.mcp_ws is ws:
            session.mcp_ws = None


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
        session = await session_mgr.spawn_session(label, voice)
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


@app.get("/api/history/{voice_id}")
async def get_history(voice_id: str):
    messages = history.load(voice_id)
    return JSONResponse({"voice_id": voice_id, "messages": messages})


@app.delete("/api/history/{voice_id}")
async def clear_history(voice_id: str):
    history.clear(voice_id)
    return JSONResponse({"status": "cleared", "voice_id": voice_id})


@app.post("/api/transcribe")
async def transcribe_audio(request: Request):
    """Transcribe audio without sending to Claude. Used by iOS PTT preview mode."""
    audio_bytes = await request.body()
    if not audio_bytes or len(audio_bytes) < 100:
        return JSONResponse({"text": ""})
    try:
        text = await stt(audio_bytes)
    except Exception as e:
        log.error("Transcription failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)
    return JSONResponse({"text": text})


@app.get("/api/settings")
async def get_settings():
    return JSONResponse(_load_settings())


@app.put("/api/settings")
async def update_settings(request: Request):
    import hub_config
    data = await request.json()
    settings = _load_settings()
    settings.update(data)
    # Apply model change at runtime
    if "model" in data and data["model"] in ("opus", "sonnet", "haiku"):
        hub_config.CLAUDE_MODEL = data["model"]
    _save_settings(settings)
    log.info("Settings updated: %s", data)
    return JSONResponse(settings)


def _load_settings() -> dict:
    settings_path = Path("data/settings.json")
    defaults = {"model": "opus", "auto_record": False, "auto_end": True, "auto_interrupt": False, "thinking_sounds": True, "audio_cues": True}
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


@app.get("/api/usage")
async def get_usage():
    """Return Claude usage stats from local cache."""
    usage_path = Path.home() / ".claude" / "usage-cache.json"
    if not usage_path.exists():
        return JSONResponse({"error": "No usage data"}, status_code=404)
    try:
        data = json.loads(usage_path.read_text())
        return JSONResponse(data)
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


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
        for name, url in [("whisper", WHISPER_URL), ("kokoro", KOKORO_URL)]:
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
    })


@app.get("/api/debug/log")
async def debug_log():
    log_path = Path("/tmp/voice-chat-hub.log")
    lines = []
    try:
        if log_path.exists():
            text = log_path.read_text()
            lines = text.strip().splitlines()[-50:]
    except Exception:
        pass
    return JSONResponse({"lines": lines})


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=HUB_PORT, log_level="info")
