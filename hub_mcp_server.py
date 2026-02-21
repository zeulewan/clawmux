"""Thin MCP server for hub-spawned Claude sessions.

Connects to the hub via WebSocket and proxies converse() calls.
The hub handles TTS/STT and browser audio routing.

Env vars:
    VOICE_HUB_SESSION_ID — session ID assigned by the hub (required)
    VOICE_CHAT_HUB_PORT  — hub port (default 3460)
"""

import asyncio
import json
import logging
import os
import sys
from contextlib import asynccontextmanager
from typing import AsyncIterator

from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed
from fastmcp import FastMCP

SESSION_ID = os.environ.get("VOICE_HUB_SESSION_ID", "")
HUB_PORT = int(os.environ.get("VOICE_CHAT_HUB_PORT", "3460"))
HUB_WS_URL = f"ws://127.0.0.1:{HUB_PORT}/mcp/{SESSION_ID}"

# Logging to stderr + file (stdout reserved for MCP stdio)
_logger = logging.getLogger("voice-hub")
_logger.setLevel(logging.DEBUG)
_fmt = logging.Formatter("%(asctime)s %(message)s", datefmt="%H:%M:%S")
_stderr = logging.StreamHandler(sys.stderr)
_stderr.setFormatter(_fmt)
_logger.addHandler(_stderr)
_file = logging.FileHandler("/tmp/voice-hub-mcp.log", mode="a")
_file.setFormatter(_fmt)
_logger.addHandler(_file)


def log(msg: str) -> None:
    _logger.info(msg)


# Shared WebSocket connection to the hub
hub_ws = None


async def connect_to_hub():
    """Connect to the hub's MCP WebSocket endpoint."""
    log(f"Connecting to hub at {HUB_WS_URL}")
    ws = await ws_connect(HUB_WS_URL)
    log("Connected to hub")
    return ws


@asynccontextmanager
async def lifespan(server: FastMCP) -> AsyncIterator[dict]:
    global hub_ws
    if not SESSION_ID:
        log("WARNING: VOICE_HUB_SESSION_ID not set")

    try:
        hub_ws = await connect_to_hub()
        log(f"Hub MCP server ready (session={SESSION_ID})")
    except Exception as e:
        log(f"Failed to connect to hub: {e}")
        hub_ws = None

    try:
        yield {}
    finally:
        if hub_ws:
            await hub_ws.close()
            log("Disconnected from hub")


mcp = FastMCP(name="voice-hub", lifespan=lifespan)


@mcp.tool
async def converse(
    message: str,
    wait_for_response: bool = True,
    voice: str = "af_sky",
    goodbye: bool = False,
) -> str:
    """Speak a message to the user via TTS and optionally listen for their spoken response via STT.

    Args:
        message: Text to speak to the user.
        wait_for_response: If True, listen for the user's spoken response after playback.
        voice: Kokoro TTS voice name (default: af_sky).
        goodbye: If True, end the session after speaking. Only use when the user explicitly says goodbye.

    Returns:
        The user's transcribed speech, or a status message if not listening.
    """
    global hub_ws
    log(f"converse(): {message!r:.80}")

    if hub_ws is None:
        return "Error: Not connected to hub."

    try:
        await hub_ws.send(json.dumps({
            "type": "converse",
            "message": message,
            "wait_for_response": wait_for_response,
            "voice": voice,
            "goodbye": goodbye,
        }))

        # Wait for result from hub
        while True:
            raw = await hub_ws.recv()
            data = json.loads(raw)
            if data["type"] == "converse_result":
                text = data["text"]
                log(f"converse() result: {text!r:.100}")
                return text

    except ConnectionClosed:
        log("Hub connection lost during converse()")
        hub_ws = None
        return "Error: Lost connection to hub."
    except Exception as e:
        log(f"converse() error: {e}")
        return f"Error: {e}"


@mcp.tool
async def voice_chat_status() -> str:
    """Check if a browser is connected to the Voice Chat Hub.

    Returns:
        Connection status string.
    """
    global hub_ws
    if hub_ws is None:
        return "Error: Not connected to hub."

    try:
        await hub_ws.send(json.dumps({"type": "status_check"}))
        while True:
            raw = await hub_ws.recv()
            data = json.loads(raw)
            if data["type"] == "status_result":
                if data["connected"]:
                    return "Connected: Browser is connected and ready."
                return f"Disconnected: Open https://workstation.tailee9084.ts.net:{HUB_PORT} in your browser."
    except Exception as e:
        return f"Error: {e}"


if __name__ == "__main__":
    mcp.run()
