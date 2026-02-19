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

from hub_config import HUB_PORT, KOKORO_URL, WHISPER_URL
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

session_mgr = SessionManager()

# Browser WebSocket (single connection, last-wins)
browser_ws: WebSocket | None = None


async def send_to_browser(data: dict) -> None:
    global browser_ws
    if browser_ws is None:
        return
    try:
        await browser_ws.send_json(data)
    except Exception as e:
        log.error("Error sending to browser: %s", e)


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

async def handle_converse(session_id: str, message: str, wait_for_response: bool, voice: str) -> str:
    """Full converse flow: TTS → browser → record → STT → return text."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return "Error: Session not found."

    session.touch()

    # Use session's voice/speed overrides
    voice = session.voice
    speed = session.speed

    # Send assistant text + status to browser
    await send_to_browser({"session_id": session_id, "type": "assistant_text", "text": message})
    await send_to_browser({"session_id": session_id, "type": "status", "text": "Speaking..."})

    # TTS
    log.info("[%s] TTS: %s", session_id, message[:80])
    mp3 = await tts(message, voice, speed)
    audio_b64 = base64.b64encode(mp3).decode()

    # Send audio to browser
    session.playback_done.clear()
    await send_to_browser({"session_id": session_id, "type": "audio", "data": audio_b64})

    if not wait_for_response:
        await send_to_browser({"session_id": session_id, "type": "done"})
        # Session ending — notify browser to close tab after playback
        await send_to_browser({"session_id": session_id, "type": "session_ended"})
        return "Message delivered."

    # Wait for playback_done from browser
    log.info("[%s] Waiting for playback_done", session_id)
    await session.playback_done.wait()

    # Drain stale audio
    while not session.audio_queue.empty():
        try:
            session.audio_queue.get_nowait()
        except asyncio.QueueEmpty:
            break

    # Tell browser to start recording
    await send_to_browser({"session_id": session_id, "type": "listening"})
    log.info("[%s] Listening...", session_id)

    # Wait for recorded audio
    audio_bytes = await session.audio_queue.get()
    log.info("[%s] Got audio: %d bytes", session_id, len(audio_bytes))

    # Empty audio = session muted in browser
    if len(audio_bytes) == 0:
        log.info("[%s] Empty audio (muted)", session_id)
        await send_to_browser({"session_id": session_id, "type": "done"})
        session.touch()
        return "(session muted)"

    # STT
    await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
    text = await stt(audio_bytes)
    log.info("[%s] STT: %s", session_id, text[:100])

    # Send user's transcribed text to browser for chat display
    if text:
        await send_to_browser({"session_id": session_id, "type": "user_text", "text": text})

    await send_to_browser({"session_id": session_id, "type": "done"})

    session.touch()
    return text if text else "(no speech detected)"


# --- FastAPI app ---

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("Hub starting on port %d", HUB_PORT)
    await session_mgr.cleanup_stale_sessions()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    try:
        yield
    finally:
        log.info("Hub shutting down, terminating all sessions")
        timeout_task.cancel()
        for sid in list(session_mgr.sessions):
            try:
                await session_mgr.terminate_session(sid)
            except Exception:
                pass


app = FastAPI(lifespan=lifespan)
STATIC_DIR = Path(__file__).parent / "static"


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "hub.html")


@app.get("/static/{filename:path}")
async def static_file(filename: str):
    path = STATIC_DIR / filename
    if path.is_file():
        return FileResponse(path)
    return JSONResponse({"error": "not found"}, status_code=404)


# --- Browser WebSocket ---

@app.websocket("/ws")
async def browser_websocket(ws: WebSocket):
    global browser_ws
    await ws.accept()
    log.info("Browser connected")

    old = browser_ws
    browser_ws = ws

    if old is not None:
        log.info("Replacing previous browser connection")

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
        log.info("Browser disconnected")
    except Exception as e:
        log.error("Browser WS error: %s: %s", type(e).__name__, e)
    finally:
        if browser_ws is ws:
            browser_ws = None
            # Unblock any waiting converse() calls
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
        audio_bytes = base64.b64decode(data["data"])
        log.info("[%s] Audio from browser: %d bytes", session_id, len(audio_bytes))
        await session.audio_queue.put(audio_bytes)


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

    session.mcp_ws = ws

    # Notify browser
    await send_to_browser({
        "type": "session_status",
        "session_id": session_id,
        "status": "ready",
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
                    )
                except Exception as e:
                    result = f"Error: {e}"
                    log.error("[%s] converse error: %s", session_id, e)

                await ws.send_json({"type": "converse_result", "text": result})

            elif msg_type == "status_check":
                await ws.send_json({
                    "type": "status_result",
                    "connected": browser_ws is not None,
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


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=HUB_PORT, log_level="info")
