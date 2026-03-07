"""ClawMux — TTS/STT Pipeline (Kokoro + Whisper).

Extracted from hub.py Phase 5a refactor.
"""

import asyncio
import base64
import json
import logging
import os
import re
import struct
from pathlib import Path

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from starlette.responses import Response as RawResponse

import hub_config

log = logging.getLogger("hub.voice")

router = APIRouter()


# ---------------------------------------------------------------------------
# Text cleanup
# ---------------------------------------------------------------------------

def _load_pronunciation_rules() -> tuple[dict, list]:
    """Load pronunciation overrides and patterns from pronunciation.json."""
    path = os.path.join(os.path.dirname(__file__), "pronunciation.json")
    try:
        with open(path) as f:
            data = json.load(f)
            overrides = data.get("overrides", {})
            patterns = data.get("patterns", [])
            return overrides, patterns
    except (FileNotFoundError, json.JSONDecodeError) as e:
        log.warning("Could not load pronunciation.json: %s", e)
        return {}, []

_pronunciation_overrides, _pronunciation_patterns = _load_pronunciation_rules()


def reload_pronunciation_overrides():
    """Reload overrides from disk (call after editing pronunciation.json)."""
    global _pronunciation_overrides, _pronunciation_patterns
    _pronunciation_overrides, _pronunciation_patterns = _load_pronunciation_rules()
    log.info("Reloaded %d overrides, %d patterns",
             len(_pronunciation_overrides), len(_pronunciation_patterns))


def apply_pronunciation_overrides(text: str) -> str:
    """Apply pronunciation overrides and regex patterns before TTS."""
    for word, replacement in _pronunciation_overrides.items():
        text = re.sub(re.escape(word), replacement, text, flags=re.IGNORECASE)
    for pattern in _pronunciation_patterns:
        text = re.sub(pattern["find"], pattern["replace"], text)
    return text


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
    text = apply_pronunciation_overrides(text)
    return text.strip()


# ---------------------------------------------------------------------------
# TTS (Kokoro)
# ---------------------------------------------------------------------------

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
    # Find how many timestamp entries belong to the prefix
    # Count words in the prefix (including punctuation as separate tokens)
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


# ---------------------------------------------------------------------------
# STT (Whisper)
# ---------------------------------------------------------------------------

def _get_stt_prompt() -> str:
    """Read STT prompt for Whisper vocabulary biasing.

    Checks (in order): CLAWMUX_STT_PROMPT env var, ClawMux .env file,
    legacy VOICEMODE_STT_PROMPT env var.
    """
    # Check env var first
    prompt = os.environ.get("CLAWMUX_STT_PROMPT")
    if prompt:
        return prompt
    # Read from ClawMux .env file
    env_path = Path(__file__).parent.parent / ".env"
    try:
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("CLAWMUX_STT_PROMPT="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
                # Legacy fallback
                if line.startswith("VOICEMODE_STT_PROMPT="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    # Legacy env var fallback
    return os.environ.get("VOICEMODE_STT_PROMPT", "")

async def stt(audio_bytes: bytes) -> str:
    """Audio bytes → text via Whisper. Retries up to 3 times on failure."""
    stt_prompt = _get_stt_prompt()
    last_err = None
    for attempt in range(3):
        try:
            data = {"model": "whisper-1", "response_format": "json"}
            if stt_prompt:
                data["prompt"] = stt_prompt
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


# ---------------------------------------------------------------------------
# REST API endpoints
# ---------------------------------------------------------------------------

@router.post("/api/transcribe")
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


@router.post("/api/tts")
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
    return RawResponse(content=audio, media_type="audio/mpeg")


@router.post("/api/tts-captioned")
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
