"""Hub configuration constants."""

import os

HUB_PORT = int(os.environ.get("VOICE_CHAT_HUB_PORT", "3460"))
SESSION_TIMEOUT_MINUTES = int(os.environ.get("VOICE_CHAT_TIMEOUT", "30"))
HEALTH_CHECK_INTERVAL_SECONDS = 15
CLAUDE_COMMAND = "claude --dangerously-skip-permissions"
TMUX_SESSION_PREFIX = "voice"
WHISPER_URL = "http://127.0.0.1:2022"
KOKORO_URL = "http://127.0.0.1:8880"

# Kokoro voices in rotation order
VOICES = [
    ("af_sky", "Sky"),
    ("af_alloy", "Alloy"),
    ("af_sarah", "Sarah"),
    ("am_adam", "Adam"),
    ("am_echo", "Echo"),
    ("am_onyx", "Onyx"),
    ("bm_fable", "Fable"),
]
