"""ClawMux MCP Server — browser audio bridge for Claude Code.

Dual-transport server:
  - FastMCP stdio ↔ Claude Code (persistent session)
  - Embedded FastAPI + WebSocket on 127.0.0.1:3456

Claude calls converse() → Kokoro TTS → browser plays audio →
browser records → Whisper STT → returns text to Claude.
"""

import asyncio
import base64
import logging
import os
import sys
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastmcp import FastMCP

WHISPER_URL = "http://127.0.0.1:2022"
KOKORO_URL = "http://127.0.0.1:8880"
WS_PORT = int(os.environ.get("VOICE_CHAT_PORT", "3456"))
LOG_FILE = "/tmp/voice-hub-mcp.log"

# Set up logging to both stderr and file
_logger = logging.getLogger("voice-hub")
_logger.setLevel(logging.DEBUG)
_fmt = logging.Formatter("%(asctime)s %(message)s", datefmt="%H:%M:%S")
_stderr_handler = logging.StreamHandler(sys.stderr)
_stderr_handler.setFormatter(_fmt)
_logger.addHandler(_stderr_handler)
_file_handler = logging.FileHandler(LOG_FILE, mode="a")
_file_handler.setFormatter(_fmt)
_logger.addHandler(_file_handler)


def log(msg: str) -> None:
    """Log to stderr and /tmp/voice-hub-mcp.log (stdout is reserved for MCP stdio)."""
    _logger.info(msg)


# --- Shared state between WebSocket and MCP tools ---


@dataclass
class Bridge:
    """Shared state between the WebSocket handler and MCP tools."""

    ws: WebSocket | None = None
    audio_queue: asyncio.Queue[bytes] = field(default_factory=asyncio.Queue)
    playback_done: asyncio.Event = field(default_factory=asyncio.Event)
    connected: asyncio.Event = field(default_factory=asyncio.Event)


bridge = Bridge()

# --- FastAPI app (WebSocket + static file serving) ---

web_app = FastAPI()


@web_app.get("/")
async def index():
    return FileResponse(Path(__file__).parent / "static" / "index.html")


@web_app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    log("Browser connected via WebSocket")

    # Last connection wins (single user)
    old_ws = bridge.ws
    bridge.ws = ws
    bridge.connected.set()

    if old_ws is not None:
        log("Replacing previous WebSocket connection")

    # Drain any stale audio from previous sessions
    drained = 0
    while not bridge.audio_queue.empty():
        try:
            bridge.audio_queue.get_nowait()
            drained += 1
        except asyncio.QueueEmpty:
            break
    if drained:
        log(f"Drained {drained} stale audio message(s) from queue")

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type")
            log(f"WS recv: type={msg_type}" + (f" data_len={len(data.get('data', ''))}" if msg_type == "audio" else ""))

            if msg_type == "audio":
                audio_bytes = base64.b64decode(data["data"])
                log(f"Audio received: {len(audio_bytes)} bytes, putting in queue (qsize={bridge.audio_queue.qsize()})")
                await bridge.audio_queue.put(audio_bytes)
                log(f"Audio queued (qsize={bridge.audio_queue.qsize()})")

            elif msg_type == "playback_done":
                log("Playback done signal received, setting event")
                bridge.playback_done.set()

    except WebSocketDisconnect:
        log("Browser disconnected (WebSocketDisconnect)")
    except Exception as e:
        log(f"WebSocket error: {type(e).__name__}: {e}")
    finally:
        if bridge.ws is ws:
            bridge.ws = None
            bridge.connected.clear()
            bridge.playback_done.set()  # Unblock any waiting converse()
            log("Bridge cleared (this was the active connection)")
        else:
            log("Old connection closed (not the active one)")


# --- FastMCP server with lifespan ---


async def run_webserver():
    """Run uvicorn, retrying every 5s if port is in use."""
    while True:
        config = uvicorn.Config(
            web_app,
            host="127.0.0.1",
            port=WS_PORT,
            log_config=None,
            log_level="error",
        )
        server = uvicorn.Server(config)
        try:
            await server.serve()
            break  # Clean exit
        except SystemExit:
            # uvicorn raises SystemExit on bind failure
            log(f"Port {WS_PORT} in use, retrying in 5s...")
            await asyncio.sleep(5)
        except Exception as e:
            log(f"WebSocket server error: {e}, retrying in 5s...")
            await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(server: FastMCP) -> AsyncIterator[dict]:
    """Start the WebSocket server alongside the MCP stdio server."""
    task = asyncio.create_task(run_webserver())
    log(f"WebSocket server starting on port {WS_PORT}")
    try:
        yield {}
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        log("WebSocket server stopped")


mcp = FastMCP(
    name="voice-hub",
    lifespan=lifespan,
)


@mcp.tool
async def converse(
    message: str,
    wait_for_response: bool = True,
    voice: str = "af_sky",
) -> str:
    """Speak a message to the user via TTS and optionally listen for their spoken response via STT.

    Args:
        message: Text to speak to the user.
        wait_for_response: If True, listen for the user's spoken response after playback.
        voice: Kokoro TTS voice name (default: af_sky).

    Returns:
        The user's transcribed speech, or a status message if not listening.
    """
    log(f"converse() called: message={message!r:.80}, wait={wait_for_response}, voice={voice}")

    if bridge.ws is None:
        log("converse() error: no browser connected")
        return "Error: No browser connected. Open the ClawMux page first."

    ws = bridge.ws

    try:
        # Send status
        await ws.send_json({"type": "status", "text": "Speaking..."})
        log("Sent status: Speaking...")

        # TTS: text → mp3
        log(f"Calling Kokoro TTS at {KOKORO_URL}...")
        async with httpx.AsyncClient(timeout=30) as client:
            tts_resp = await client.post(
                f"{KOKORO_URL}/v1/audio/speech",
                json={
                    "model": "tts-1",
                    "input": message,
                    "voice": voice,
                    "response_format": "mp3",
                },
            )
            tts_resp.raise_for_status()
        log(f"TTS response: {len(tts_resp.content)} bytes MP3")

        # Send audio to browser
        audio_b64 = base64.b64encode(tts_resp.content).decode()
        bridge.playback_done.clear()
        await ws.send_json({"type": "audio", "data": audio_b64})
        log(f"Sent audio to browser ({len(audio_b64)} chars b64)")

        if not wait_for_response:
            await ws.send_json({"type": "done"})
            log("converse() done (no wait)")
            return "Message delivered."

        # Wait for browser to finish playing audio (no timeout — long TTS can take minutes)
        log("Waiting for playback_done event...")
        await bridge.playback_done.wait()
        log("Playback done")

        if bridge.ws is None:
            log("converse() error: browser disconnected during playback")
            return "Error: Browser disconnected during playback."

        # Drain stale audio
        drained = 0
        while not bridge.audio_queue.empty():
            try:
                bridge.audio_queue.get_nowait()
                drained += 1
            except asyncio.QueueEmpty:
                break
        if drained:
            log(f"Drained {drained} stale audio message(s)")

        # Tell browser to start recording
        await ws.send_json({"type": "listening"})
        log("Sent listening signal, waiting for recorded audio...")

        # Wait for recorded audio (no timeout — user taps to stop when ready)
        audio_bytes = await bridge.audio_queue.get()
        log(f"Got recorded audio: {len(audio_bytes)} bytes")

        if bridge.ws is None:
            log("converse() error: browser disconnected during recording")
            return "Error: Browser disconnected during recording."

        # STT: webm → text
        await ws.send_json({"type": "status", "text": "Transcribing..."})
        log(f"Calling Whisper STT at {WHISPER_URL}...")
        async with httpx.AsyncClient(timeout=30) as client:
            stt_resp = await client.post(
                f"{WHISPER_URL}/v1/audio/transcriptions",
                files={
                    "file": ("recording.webm", audio_bytes, "audio/webm"),
                },
                data={"model": "whisper-1", "response_format": "json"},
            )
            stt_resp.raise_for_status()

        text = stt_resp.json().get("text", "").strip()
        log(f"STT result: {text!r:.100}")
        if not text:
            await ws.send_json({"type": "done"})
            return "(no speech detected)"

        await ws.send_json({"type": "done"})
        log(f"converse() returning: {text!r:.100}")
        return text

    except WebSocketDisconnect:
        log("converse() error: WebSocketDisconnect")
        return "Error: Browser disconnected."
    except Exception as e:
        log(f"converse() error: {type(e).__name__}: {e}")
        return f"Error: {e}"


@mcp.tool
async def voice_chat_status() -> str:
    """Check if a browser is connected to the ClawMux WebSocket.

    Returns:
        Connection status string.
    """
    connected = bridge.ws is not None
    log(f"voice_chat_status() called: connected={connected}")
    if connected:
        return "Connected: Browser is connected and ready."
    return "Disconnected: No browser connected. Open https://workstation.tailee9084.ts.net:3456 in your browser."


if __name__ == "__main__":
    mcp.run()
