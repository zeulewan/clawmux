"""ClawMux — session launcher, TTS/STT engine, and WebSocket multiplexer.

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
from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse

from history_store import HistoryStore
import hub_config
from hub_config import HUB_PORT, HUB_START_TIME
import inbox
from message_broker import MessageBroker
from project_manager import ProjectManager
from session_manager import SessionManager

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
session_mgr = SessionManager(history_store=history, project_mgr=project_mgr)
broker = MessageBroker()


def _hist_prefix(session) -> str | None:
    """Get the history prefix for a session's project."""
    return project_mgr.get_history_prefix(session.project_slug)


def _gen_msg_id() -> str:
    """Generate a short unique message ID for history tracking."""
    return "msg-" + uuid.uuid4().hex[:8]

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
            if not session or session.status == "dead":
                continue
            # Only check when context usage is >= 80%
            usage = session_mgr.get_context_usage(session_id)
            if not usage or usage["percent"] < 80:
                if session.compacting:
                    # Context dropped below 80% (post-compaction reset)
                    session.compacting = False
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
            if is_compacting != session.compacting:
                session.compacting = is_compacting
                await send_to_browser({
                    "type": "compaction_status",
                    "session_id": session_id,
                    "compacting": is_compacting,
                })
                log.info("[%s] Compaction %s", session_id, "started" if is_compacting else "finished")


# --- TTS / STT ---

def strip_non_speakable(text: str) -> str:
    """Convert markdown to plain text suitable for speech synthesis.

    Keeps the readable content but removes formatting symbols that Kokoro
    would otherwise read aloud (e.g. '##', '|', '```', '---', '$$').
    """
    # Remove fenced code blocks (```...```) — keep the code inside
    text = re.sub(r'```\w*\n?', '', text)
    # Remove display math ($$...$$)
    text = re.sub(r'\$\$[\s\S]*?\$\$', '', text)
    # Remove inline math ($...$)
    text = re.sub(r'\$([^\$\n]+?)\$', '', text)
    # Remove LaTeX delimiters \[...\] and \(...\)
    text = re.sub(r'\\\[[\s\S]*?\\\]', '', text)
    text = re.sub(r'\\\([\s\S]*?\\\)', '', text)
    # Remove inline code backticks but keep the text
    text = re.sub(r'`([^`]+)`', r'\1', text)
    # Remove images ![alt](url) → alt
    text = re.sub(r'!\[([^\]]*)\]\([^)]+\)', r'\1', text)
    # Remove links [text](url) → text
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    # Remove HTML tags (like <u>underline</u>)
    text = re.sub(r'<[^>]+>', '', text)
    # Remove heading markers
    text = re.sub(r'^#{1,6}\s+', '', text, flags=re.MULTILINE)
    # Remove horizontal rules (---, ***, ___)
    text = re.sub(r'^[\s]*[-*_]{3,}\s*$', '', text, flags=re.MULTILINE)
    # Remove bold/italic markers (**, __, *, _) but keep the text
    text = re.sub(r'\*{1,3}([^*]+)\*{1,3}', r'\1', text)
    text = re.sub(r'_{1,3}([^_]+)_{1,3}', r'\1', text)
    # Remove blockquote markers
    text = re.sub(r'^>\s?', '', text, flags=re.MULTILINE)
    # Convert markdown tables to spoken form:
    # Remove separator rows (|---|---|)
    text = re.sub(r'^\|[\s\-:|]+\|\s*$', '', text, flags=re.MULTILINE)
    # Convert table rows: | A | B | C | → A, B, C
    def _table_row(m):
        cells = [c.strip() for c in m.group(0).split('|') if c.strip()]
        return ', '.join(cells)
    text = re.sub(r'^\|(.+)\|\s*$', _table_row, text, flags=re.MULTILINE)
    # Remove bullet markers (-, *, +) at line start
    text = re.sub(r'^[\s]*[-*+]\s+', '', text, flags=re.MULTILINE)
    # Remove numbered list markers (1., 2., etc.)
    text = re.sub(r'^[\s]*\d+\.\s+', '', text, flags=re.MULTILINE)
    # Collapse multiple blank lines into one
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


async def tts(text: str, voice: str = "af_sky", speed: float = 1.0) -> bytes:
    """Text → MP3 bytes via Kokoro. Retries up to 3 times on failure."""
    last_err = None
    for attempt in range(3):
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    f"{hub_config.KOKORO_URL}/v1/audio/speech",
                    json={"model": "tts-1", "input": text, "voice": voice, "response_format": "mp3", "speed": speed},
                )
                resp.raise_for_status()
            return resp.content
        except Exception as e:
            last_err = e
            if attempt < 2:
                log.warning("TTS attempt %d failed: %s, retrying...", attempt + 1, e)
                await asyncio.sleep(1 * (attempt + 1))
    raise last_err


async def tts_captioned(text: str, voice: str = "af_sky", speed: float = 1.0) -> tuple[str, list]:
    """Text → (audio_b64, word_timestamps) via Kokoro captioned speech endpoint."""
    # At higher speeds, Kokoro clips the very beginning of the audio.
    # Workaround: prepend a dummy word so the real first word isn't clipped,
    # then strip the dummy from audio and timestamps.
    # Scale prefix length based on speed — more warmup needed at higher speeds
    if speed >= 2.0:
        PREFIX = "Hmm, well,"
    elif speed >= 1.5:
        PREFIX = "Hmm,"
    else:
        PREFIX = None
    use_prefix = PREFIX is not None
    tts_input = f"{PREFIX} {text}" if use_prefix else text

    last_err = None
    for attempt in range(3):
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    f"{hub_config.KOKORO_URL}/dev/captioned_speech",
                    json={"input": tts_input, "voice": voice, "speed": speed,
                           "stream": False, "return_timestamps": True,
                           "response_format": "wav"},
                )
                resp.raise_for_status()
                data = resp.json()
                audio_b64 = data["audio"]
                timestamps = data.get("timestamps", [])

                if use_prefix and timestamps:
                    audio_b64, timestamps = _strip_prefix_audio(audio_b64, timestamps, PREFIX)

                return audio_b64, timestamps
        except Exception as e:
            last_err = e
            if attempt < 2:
                log.warning("TTS captioned attempt %d failed: %s, retrying...", attempt + 1, e)
                await asyncio.sleep(1 * (attempt + 1))
    raise last_err


def _strip_prefix_audio(audio_b64: str, timestamps: list, prefix: str) -> tuple[str, list]:
    """Strip the prefix word(s) from audio and timestamps, keeping only the real content."""
    import base64, struct

    # Find how many timestamp entries belong to the prefix
    # Count words in the prefix (including punctuation as separate tokens)
    import re
    prefix_tokens = set(re.findall(r'\w+|[^\w\s]', prefix.lower()))
    cut_idx = 0
    for i, ts in enumerate(timestamps):
        w = ts["word"].strip().lower()
        if w in prefix_tokens or w in (".", "...", ",", "-", "—", ""):
            cut_idx = i + 1
        else:
            break  # hit a real word
    if cut_idx == 0:
        return audio_b64, timestamps  # no prefix found to strip

    # The cut time is the start of the first real word
    cut_time = timestamps[cut_idx]["start_time"] if cut_idx < len(timestamps) else 0
    # Add margin before the real first word to avoid clipping
    cut_time = max(0, cut_time - 0.05)

    raw = base64.b64decode(audio_b64)
    if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
        return audio_b64, timestamps

    # Parse WAV to find data chunk
    pos = 12
    sample_rate = 24000
    bits_per_sample = 16
    num_channels = 1
    data_start = 0
    fmt_data = b''

    while pos < len(raw) - 8:
        chunk_id = raw[pos:pos+4]
        chunk_size = struct.unpack_from('<I', raw, pos+4)[0]
        if chunk_id == b'fmt ':
            num_channels = struct.unpack_from('<H', raw, pos+10)[0]
            sample_rate = struct.unpack_from('<I', raw, pos+12)[0]
            bits_per_sample = struct.unpack_from('<H', raw, pos+22)[0]
            fmt_data = raw[pos:pos+8+chunk_size]
        elif chunk_id == b'data':
            data_start = pos + 8
            break
        pos += 8 + chunk_size
        if chunk_size % 2:
            pos += 1

    if data_start == 0:
        return audio_b64, timestamps

    pcm_data = raw[data_start:]
    bytes_per_sample = bits_per_sample // 8
    frame_size = num_channels * bytes_per_sample
    cut_sample = int(cut_time * sample_rate)
    cut_bytes = cut_sample * frame_size

    if cut_bytes >= len(pcm_data):
        return audio_b64, timestamps

    trimmed_pcm = pcm_data[cut_bytes:]
    new_data_size = len(trimmed_pcm)

    # Build new WAV
    wav = bytearray()
    wav += b'RIFF'
    wav += struct.pack('<I', 0)  # placeholder for file size
    wav += b'WAVE'
    wav += fmt_data
    wav += b'data'
    wav += struct.pack('<I', new_data_size)
    wav += trimmed_pcm
    struct.pack_into('<I', wav, 4, len(wav) - 8)

    trimmed_b64 = base64.b64encode(bytes(wav)).decode()

    # Shift timestamps: remove prefix entries, adjust times
    shifted = []
    for ts in timestamps[cut_idx:]:
        shifted.append({
            **ts,
            "start_time": max(0, ts["start_time"] - cut_time),
            "end_time": ts["end_time"] - cut_time,
        })
    return trimmed_b64, shifted


def _get_stt_prompt() -> str:
    """Read STT prompt from voicemode.env for Whisper vocabulary biasing."""
    env_path = os.path.expanduser("~/.voicemode/voicemode.env")
    try:
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("VOICEMODE_STT_PROMPT="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return val
    except FileNotFoundError:
        pass
    return os.environ.get("VOICEMODE_STT_PROMPT", "")

_stt_prompt = _get_stt_prompt()


async def stt(audio_bytes: bytes) -> str:
    """Audio bytes → text via Whisper. Retries up to 3 times on failure."""
    last_err = None
    for attempt in range(3):
        try:
            data = {"model": "whisper-1", "response_format": "json"}
            if _stt_prompt:
                data["prompt"] = _stt_prompt
            async with httpx.AsyncClient(timeout=30) as client:
                resp = await client.post(
                    f"{hub_config.WHISPER_URL}/v1/audio/transcriptions",
                    files={"file": ("recording.webm", audio_bytes, "audio/webm")},
                    data=data,
                )
                resp.raise_for_status()
            return resp.json().get("text", "").strip()
        except Exception as e:
            last_err = e
            if attempt < 2:
                log.warning("STT attempt %d failed: %s, retrying...", attempt + 1, e)
                await asyncio.sleep(1 * (attempt + 1))
    raise last_err


# --- Converse logic (called by MCP sessions via WS) ---

async def handle_converse(session_id: str, message: str, wait_for_response: bool, voice: str, goodbye: bool = False) -> str:
    """Full converse flow: TTS → browser → record → STT → return text."""
    session = session_mgr.sessions.get(session_id)
    if not session:
        return "Error: Session not found."

    session.touch()
    session.last_converse_time = time.time()
    session.reinject_attempts = 0  # Reset re-injection counter on successful converse

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
        history.clear_interjections(session.voice, _hist_prefix(session))
        log.info("[%s] Pre-speech interjection(s), skipping TTS: %s", session_id, text[:100])
        # Persist to history and show in browser (but don't speak it)
        if message:
            mid = _gen_msg_id()
            history.append(session.voice, session.label, "assistant", message, _hist_prefix(session), msg_id=mid)
            if session_id != _browser_viewed_session:
                session.unread_count += 1
            await send_to_browser({"session_id": session_id, "type": "assistant_text", "text": message, "msg_id": mid})
        session.status_text = ""
        session.processing = True  # Agent will process the interjection
        await send_to_browser({"session_id": session_id, "type": "done", "processing": True})
        session.touch()
        return text

    # Empty message = silent listen (skip TTS and chat display entirely)
    silent = not message

    if not silent:
        # Persist to history FIRST so sync can recover if hub crashes mid-delivery
        mid = _gen_msg_id()
        history.append(session.voice, session.label, "assistant", message, _hist_prefix(session), msg_id=mid)

        # Signal that Claude is about to speak (lets client show thinking indicator)
        await send_to_browser({"session_id": session_id, "type": "thinking"})

        # Send assistant text to browser for chat display
        if session_id != _browser_viewed_session:
            session.unread_count += 1
        await send_to_browser({"session_id": session_id, "type": "assistant_text", "text": message, "msg_id": mid})

    # Skip TTS if silent, in text mode, or voice responses disabled
    skip_tts = silent or session.text_mode or not _load_settings().get("voice_responses", True)
    if skip_tts:
        # Text mode: skip TTS entirely, go straight to listen phase
        log.info("[%s] Text mode, skipping TTS: %s", session_id, message[:80])
        if not wait_for_response:
            session.status_text = ""
            session.processing = False  # Fire-and-forget: agent won't call back
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
            if goodbye:
                await send_to_browser({"session_id": session_id, "type": "session_ended"})
            return "Message delivered."
        early_audio = None
    else:
        session.status_text = "Speaking..."
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Speaking..."})

        # TTS — strip code blocks, equations, tables before speaking
        tts_message = strip_non_speakable(message)
        log.info("[%s] TTS: %s", session_id, tts_message[:80])
        if not tts_message.strip():
            # Nothing speakable — skip TTS entirely
            log.info("[%s] No speakable content, skipping TTS", session_id)
            audio_b64, word_timestamps = None, []
        else:
            try:
                audio_b64, word_timestamps = await tts_captioned(tts_message, voice, speed)
            except Exception as e:
                log.warning("[%s] Captioned TTS failed (%s), falling back to plain TTS", session_id, e)
                mp3 = await tts(tts_message, voice, speed)
                audio_b64 = base64.b64encode(mp3).decode()
                word_timestamps = []

        # Send audio to browser (skip if nothing speakable)
        if audio_b64 is None:
            session.playback_done.set()
            early_audio = None
        else:
            session.playback_done.clear()
            audio_msg = {"session_id": session_id, "type": "audio", "data": audio_b64}
            if word_timestamps:
                audio_msg["words"] = word_timestamps
            has_clients = await send_to_browser(audio_msg)

            if not has_clients:
                # No clients received the audio — no one will send playback_done
                log.warning("[%s] No clients connected, skipping playback wait", session_id)
                session.playback_done.set()

        if not wait_for_response:
            session.status_text = ""
            session.processing = False  # Fire-and-forget: agent won't call back
            await send_to_browser({"session_id": session_id, "type": "done", "processing": False})
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
        history.clear_interjections(session.voice, _hist_prefix(session))
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
        # Also watch inbox for messages arriving during listen phase
        while True:
            try:
                audio_bytes = await asyncio.wait_for(session.audio_queue.get(), timeout=5)
                break
            except asyncio.TimeoutError:
                # Check inbox for messages that arrived during listen
                if session.work_dir:
                    inbox_msgs = inbox.read_and_clear(session.work_dir)
                    if inbox_msgs:
                        formatted = _format_inbox_messages(inbox_msgs)
                        log.info("[%s] Inbox messages during listen: %d", session_id, len(inbox_msgs))
                        session.interjections.append(formatted)
                        session.text_override = " ... ".join(session.interjections)
                        session.interjections.clear()
                        history.clear_interjections(session.voice, _hist_prefix(session))
                        await session.audio_queue.put(b"__text__")
                        await send_to_browser({
                            "type": "inbox_update",
                            "session_id": session_id,
                            "count": 0,
                        })
                        continue  # Loop back to get the __text__ marker
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

    # Text override (typed input from client or interjection) or STT
    text_already_shown = False
    if audio_bytes == b"__text__" and session.text_override:
        text = session.text_override
        text_already_shown = True  # interjection handler already sent user_text + history
        session.text_override = ""
        log.info("[%s] Text input: %s", session_id, text[:100])
    else:
        session.status_text = "Transcribing..."
        await send_to_browser({"session_id": session_id, "type": "status", "text": "Transcribing..."})
        text = await stt(audio_bytes)
        log.info("[%s] STT: %s", session_id, text[:100])

    # Send user's transcribed text to browser for chat display
    if text and not text_already_shown:
        umid = _gen_msg_id()
        await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
        history.append(session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)

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
    broker.start()
    timeout_task = asyncio.create_task(session_mgr.run_timeout_loop())
    hb_task = asyncio.create_task(heartbeat_loop())
    compaction_task = asyncio.create_task(compaction_monitor_loop())
    try:
        yield
    finally:
        broker.stop()
        timeout_task.cancel()
        hb_task.cancel()
        compaction_task.cancel()
        if _shutdown_mode == "reload":
            log.info("Hub reloading — keeping tmux sessions alive for re-adoption")
            # Drain pending audio from queues and save as interjections before shutdown
            for sid, session in session_mgr.sessions.items():
                pending_audio = []
                while not session.audio_queue.empty():
                    try:
                        item = session.audio_queue.get_nowait()
                        if item and item not in (b"", b"__text__") and len(item) > 100:
                            pending_audio.append(item)
                    except Exception:
                        break
                if pending_audio:
                    log.info("[%s] Transcribing %d pending audio chunk(s) before reload", sid, len(pending_audio))
                    for audio_bytes in pending_audio:
                        try:
                            text = await stt(audio_bytes)
                            if text and text.strip():
                                session.interjections.append(text)
                                log.info("[%s] Saved pending audio as interjection: %s", sid, text[:80])
                        except Exception as e:
                            log.warning("[%s] Failed to transcribe pending audio: %s", sid, e)
                    if session.interjections:
                        history.save_interjections(session.voice, session.interjections, _hist_prefix(session))
            for sid, session in session_mgr.sessions.items():
                if session.mcp_ws:
                    try:
                        await session.mcp_ws.close(code=1001, reason="Hub reloading")
                    except Exception:
                        pass
        else:
            log.info("Hub shutting down, terminating all sessions")
            for sid in list(session_mgr.sessions):
                try:
                    await session_mgr.terminate_session(sid)
                except Exception:
                    pass


app = FastAPI(lifespan=lifespan)
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
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "msg_id": umid})
            history.append(session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)
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
            history.save_interjections(session.voice, session.interjections, _hist_prefix(session))
            umid = _gen_msg_id()
            await send_to_browser({"session_id": session_id, "type": "user_text", "text": text, "interjection": True, "msg_id": umid})
            history.append(session.voice, session.label, "user", text, _hist_prefix(session), msg_id=umid)

            # If agent is in an active converse call waiting for audio, inject
            # the interjection as audio queue input so it gets picked up immediately
            if session.in_converse:
                log.info("[%s] Agent in converse, injecting interjection via audio queue", session_id)
                session.text_override = " ... ".join(session.interjections)
                session.interjections.clear()
                history.clear_interjections(session.voice, _hist_prefix(session))
                await session.audio_queue.put(b"__text__")
            elif session.work_dir:
                # Agent NOT in converse — write to inbox for hook-based delivery
                # (PostToolUse/PreToolUse will pick it up via additionalContext)
                sender_name = data.get("voice", session.voice or "user")
                sender_name = sender_name.replace("af_", "").replace("am_", "").replace("bm_", "")
                await _inbox_write_and_notify(session, {
                    "from": sender_name,
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
    session.in_converse = True  # Agent is idle and ready for input

    # Tell browser agent is listening (so voice input isn't treated as interjection)
    await send_to_browser({"session_id": session_id, "type": "listening"})

    # Register this WS for push notifications
    if not hasattr(session, "_wait_queue"):
        session._wait_queue = asyncio.Queue()

    try:
        # First, check if there are already pending inbox messages
        if session.work_dir:
            messages = inbox.read_and_clear(session.work_dir)
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
                await ws.send_json({"type": "messages", "messages": [msg]})
                return
            except asyncio.TimeoutError:
                # Check inbox file as fallback (in case message was written directly)
                if session.work_dir:
                    messages = inbox.read_and_clear(session.work_dir)
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
        session.in_converse = False
        if hasattr(session, "_wait_queue"):
            del session._wait_queue


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
        msg_id = msg.get("id", "")
        if msg_type == "agent":
            lines.append(f"[MSG id:{msg_id} from:{sender}] {content}")
        elif msg_type == "voice":
            lines.append(f"[VOICE from:{sender}] {content}")
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
        session.status_text = ""
        # Check inbox for pending messages — deliver via additionalContext
        if session.work_dir:
            messages = inbox.read_and_clear(session.work_dir)
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
        session.status_text = ""
        session.processing = False
    elif event == "PreToolUse":
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        session.status_text = _tool_status_text(tool_name, tool_input)
        session.processing = True
        # Check inbox for urgent messages — deliver via additionalContext
        if session.work_dir:
            messages = inbox.read_and_clear(session.work_dir)
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
            messages = inbox.read_and_clear(session.work_dir)
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
        # SessionStart hook — mark session active, inject any pending inbox
        session.processing = True
        session.status_text = "Starting session..."
        if session.work_dir:
            messages = inbox.read_and_clear(session.work_dir)
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
        session.status_text = "Compacting context..."
    else:
        return JSONResponse({})

    msg = {
        "type": "session_status",
        "session_id": session.session_id,
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
        mode = body.get("mode", "mcp")  # "mcp" (default) or "cli"
        project = body.get("project")
        session = await session_mgr.spawn_session(label, voice, mode=mode, project=project)
        # Notify browser of the new session so the sidebar updates immediately
        await send_to_browser({"type": "session_spawned", "session": session.to_dict()})
        # Show thinking indicator while agent prepares its opening greeting
        session.processing = True
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
            for sid, session in session_mgr.sessions.items():
                if session.mcp_ws:
                    try:
                        await session.mcp_ws.close(code=1001, reason="Hub reloading")
                    except Exception:
                        pass
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
        project_mgr.delete_project(slug)
        return JSONResponse({"status": "deleted", "slug": slug, "terminated_sessions": len(to_terminate)})
    except ValueError as e:
        return JSONResponse({"error": str(e)}, status_code=400)


@app.get("/api/history/{voice_id}")
async def get_history(voice_id: str, request: Request):
    # Use project from query param or active project
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    messages = history.load(voice_id, prefix)
    # Include count of pending interjections so browser can style unseen messages
    pending_count = 0
    for s in session_mgr.sessions.values():
        if s.voice == voice_id and s.interjections:
            pending_count = len(s.interjections)
            break
    return JSONResponse({"voice_id": voice_id, "messages": messages, "pending_interjections": pending_count})


@app.delete("/api/history/{voice_id}")
async def clear_history(voice_id: str, request: Request):
    project = request.query_params.get("project", project_mgr.active_project)
    prefix = project_mgr.get_history_prefix(project)
    history.clear(voice_id, prefix)
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

    # Always use converse pipeline for inter-agent messages (no tmux injection)
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
    # - In converse → converse pipeline (immediate, agent sees it now)
    # - Not in converse → inbox (hooks deliver via additionalContext)
    formatted = f"[MSG id:{msg.id} from:{sender_name}] {content}"
    if recipient.in_converse and recipient.audio_queue:
        # Converse pipeline — immediate delivery
        recipient.interjections.append(formatted)
        recipient.text_override = " ... ".join(recipient.interjections)
        recipient.interjections.clear()
        await recipient.audio_queue.put(b"__text__")
        log.info("[%s] Message %s injected via converse pipeline", recipient.session_id, msg.id)
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
        # Fallback — no inbox, no converse, queue as interjection
        recipient.interjections.append(formatted)
        log.info("[%s] Message %s queued as interjection (fallback)", recipient.session_id, msg.id)

    # Save to history so messages persist across browser reloads
    is_bare_ack = bool(parent_id and not content)
    history.append(recipient.voice, recipient.label, "system",
                   f"[Agent msg from {sender_name.capitalize()}] {content}",
                   _hist_prefix(recipient),
                   msg_id=msg.id, parent_id=parent_id or None, bare_ack=is_bare_ack)
    history.append(sender.voice, sender.label, "system",
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
        msg_id = f"msg-{uuid.uuid4().hex[:8]}"
        sender_name = sender.voice.replace("af_", "").replace("am_", "").replace("bm_", "")
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
    msg_id = f"msg-{uuid.uuid4().hex[:8]}"

    # Save to history
    amid = _gen_msg_id()
    history.append(sender.voice, sender.label, "assistant", content, _hist_prefix(sender), msg_id=amid)
    if sender_id != _browser_viewed_session:
        sender.unread_count += 1

    # Send text to browser chat (fire_and_forget prevents auto-record trigger)
    await send_to_browser({"session_id": sender_id, "type": "assistant_text", "text": content, "msg_id": amid, "fire_and_forget": True})

    # TTS — strip non-speakable content and play
    skip_tts = sender.text_mode or not _load_settings().get("voice_responses", True)
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
    messages = inbox.read_and_clear(session.work_dir)
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
    count = inbox.peek(session.work_dir)
    latest = inbox.peek_latest(session.work_dir) if count > 0 else None
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
    written = inbox.write(session.work_dir, msg_dict)
    count = inbox.peek(session.work_dir)
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
    # Push to wait WS if connected (for clawmux wait)
    if hasattr(session, "_wait_queue"):
        try:
            session._wait_queue.put_nowait(written)
        except Exception:
            pass
    return written


# ---------------------------------------------------------------------------
# Audio API
# ---------------------------------------------------------------------------

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


@app.post("/api/tts")
async def text_to_speech(request: Request):
    """Generate TTS audio for arbitrary text. Returns MP3 bytes."""
    data = await request.json()
    text = data.get("text", "").strip()
    voice = data.get("voice", "af_sky")
    speed = data.get("speed", 1.0)
    if not text:
        return JSONResponse({"error": "no text"}, status_code=400)
    try:
        audio = await tts(strip_non_speakable(text), voice=voice, speed=speed)
    except Exception as e:
        log.error("TTS failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)
    from starlette.responses import Response as RawResponse
    return RawResponse(content=audio, media_type="audio/mpeg")


@app.post("/api/tts-captioned")
async def text_to_speech_captioned(request: Request):
    """Generate TTS with word timestamps. Returns JSON {audio_b64, words}."""
    data = await request.json()
    text = data.get("text", "").strip()
    voice = data.get("voice", "af_sky")
    speed = data.get("speed", 1.0)
    if not text:
        return JSONResponse({"error": "no text"}, status_code=400)
    try:
        audio_b64, words = await tts_captioned(strip_non_speakable(text), voice=voice, speed=speed)
        return JSONResponse({"audio_b64": audio_b64, "words": words})
    except Exception as e:
        log.error("TTS captioned failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)


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
        log.info("Quality mode changed to: %s (model: %s)", data["quality_mode"],
                 hub_config.QUALITY_MODEL_MAP.get(data["quality_mode"]))
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


@app.get("/api/context")
async def get_context():
    """Return context window usage for all active sessions."""
    result = {}
    for sid in session_mgr.sessions:
        usage = session_mgr.get_context_usage(sid)
        if usage:
            result[sid] = usage
    return JSONResponse(result)


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
