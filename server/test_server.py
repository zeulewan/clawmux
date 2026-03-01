#!/usr/bin/env python3
"""Test the voice-hub MCP server end-to-end.

Tests:
  python test_server.py           # Basic: HTTP, WebSocket, services
  python test_server.py --full    # Full: simulate browser + converse() flow
"""

import asyncio
import base64
import json
import os
import sys

import httpx

# Use test port to avoid conflict with running MCP server
TEST_PORT = int(os.environ.get("TEST_PORT", "3457"))
os.environ["VOICE_CHAT_PORT"] = str(TEST_PORT)

WS_URL = f"ws://127.0.0.1:{TEST_PORT}/ws"
HTTP_URL = f"http://127.0.0.1:{TEST_PORT}"
WHISPER_URL = "http://127.0.0.1:2022"
KOKORO_URL = "http://127.0.0.1:8880"


def ok(msg):
    print(f"  OK: {msg}")


def fail(msg):
    print(f"  FAIL: {msg}")


def section(msg):
    print(f"\n--- {msg} ---")


async def test_services():
    """Test that Whisper and Kokoro are reachable."""
    section("Services: Whisper + Kokoro")
    passed = 0

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{KOKORO_URL}/v1/audio/speech",
                json={"model": "tts-1", "input": "test", "voice": "af_sky", "response_format": "mp3"},
            )
            resp.raise_for_status()
            ok(f"Kokoro TTS: {len(resp.content)} bytes MP3")
            passed += 1
    except Exception as e:
        fail(f"Kokoro TTS: {e}")

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            tts = await client.post(
                f"{KOKORO_URL}/v1/audio/speech",
                json={"model": "tts-1", "input": "hello world", "voice": "af_sky", "response_format": "mp3"},
            )
            stt = await client.post(
                f"{WHISPER_URL}/v1/audio/transcriptions",
                files={"file": ("test.mp3", tts.content, "audio/mpeg")},
                data={"model": "whisper-1", "response_format": "json"},
            )
            stt.raise_for_status()
            text = stt.json().get("text", "").strip()
            ok(f"Whisper STT round-trip: '{text}'")
            passed += 1
    except Exception as e:
        fail(f"Whisper STT: {e}")

    return passed == 2


async def test_tool_logic():
    """Test tool functions directly (no MCP protocol, no server)."""
    section("Tool logic: direct function calls")
    from mcp_server import bridge, converse as converse_tool, voice_chat_status as status_tool

    fn_status = status_tool.fn
    fn_converse = converse_tool.fn
    passed = 0

    result = await fn_status()
    if "Disconnected" in result:
        ok(f"voice_chat_status (no browser): {result[:60]}")
        passed += 1
    else:
        fail(f"Expected Disconnected, got: {result}")

    result = await fn_converse("Hello", wait_for_response=False)
    if "No browser" in result:
        ok(f"converse (no browser): {result[:60]}")
        passed += 1
    else:
        fail(f"Expected No browser error, got: {result}")

    return passed == 2


async def test_full_flow():
    """Full integration: start server, connect fake browser, invoke converse()."""
    section("Full flow: server + fake browser + converse()")

    import websockets
    from mcp_server import bridge, converse as converse_tool, web_app
    import uvicorn

    fn_converse = converse_tool.fn

    # Start uvicorn on test port
    config = uvicorn.Config(web_app, host="127.0.0.1", port=TEST_PORT, log_config=None, log_level="error")
    server = uvicorn.Server(config)
    server_task = asyncio.create_task(server.serve())
    await asyncio.sleep(0.5)  # let server bind

    try:
        # Connect fake browser
        ws = await websockets.connect(WS_URL)
        ok("Fake browser connected")
        await asyncio.sleep(0.2)

        # Run converse() in background — it will TTS, send audio, wait for playback_done
        async def run_converse():
            return await fn_converse("This is a test greeting", wait_for_response=True, voice="af_sky")

        converse_task = asyncio.create_task(run_converse())

        # Browser side: receive status
        raw = await asyncio.wait_for(ws.recv(), timeout=10)
        msg = json.loads(raw)
        assert msg["type"] == "status", f"Expected status, got {msg['type']}"
        ok(f"Got status: {msg['text']}")

        # Receive TTS audio
        raw = await asyncio.wait_for(ws.recv(), timeout=15)
        msg = json.loads(raw)
        assert msg["type"] == "audio", f"Expected audio, got {msg['type']}"
        audio_bytes = base64.b64decode(msg["data"])
        ok(f"Got TTS audio: {len(audio_bytes)} bytes")

        # Send playback_done
        await ws.send(json.dumps({"type": "playback_done"}))
        ok("Sent playback_done")

        # Receive listening signal
        raw = await asyncio.wait_for(ws.recv(), timeout=10)
        msg = json.loads(raw)
        assert msg["type"] == "listening", f"Expected listening, got {msg['type']}"
        ok("Got listening signal")

        # Generate fake recording (TTS of a known phrase) and send as audio
        async with httpx.AsyncClient(timeout=10) as client:
            tts = await client.post(
                f"{KOKORO_URL}/v1/audio/speech",
                json={"model": "tts-1", "input": "I said hello back", "voice": "af_sky", "response_format": "mp3"},
            )
        audio_b64 = base64.b64encode(tts.content).decode()
        await ws.send(json.dumps({"type": "audio", "data": audio_b64}))
        ok(f"Sent fake recorded audio: {len(tts.content)} bytes")

        # Wait for converse() to finish (it does STT and returns text)
        result = await asyncio.wait_for(converse_task, timeout=15)
        ok(f"converse() returned: '{result}'")

        # Receive remaining WS messages (status: Transcribing, done)
        remaining = []
        try:
            while True:
                raw = await asyncio.wait_for(ws.recv(), timeout=1)
                remaining.append(json.loads(raw))
        except (asyncio.TimeoutError, websockets.exceptions.ConnectionClosed):
            pass
        for m in remaining:
            ok(f"WS message: type={m['type']} {m.get('text', '')}")

        await ws.close()
        ok("Full flow completed successfully!")
        return True

    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        server.should_exit = True
        await server_task


async def main():
    print("Voice Hub MCP Server Tests")
    print("=" * 50)

    results = []
    results.append(await test_services())
    results.append(await test_tool_logic())

    if "--full" in sys.argv:
        results.append(await test_full_flow())

    print("\n" + "=" * 50)
    passed = sum(results)
    total = len(results)
    status = "PASS" if passed == total else "FAIL"
    print(f"{status}: {passed}/{total} test groups passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
