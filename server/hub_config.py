"""Hub configuration constants."""

import os
import time

HUB_PORT = int(os.environ.get("CLAWMUX_PORT", "3460"))
HUB_START_TIME = time.time()
SESSION_TIMEOUT_MINUTES = int(os.environ.get("VOICE_CHAT_TIMEOUT", "0"))  # 0 = never timeout
HEALTH_CHECK_INTERVAL_SECONDS = 15
CLAUDE_BASE_COMMAND = "claude --dangerously-skip-permissions"
CLAUDE_MODEL = os.environ.get("VOICE_CHAT_MODEL", "opus")  # opus, sonnet, haiku
TMUX_SESSION_PREFIX = "voice"
WHISPER_URL = "http://127.0.0.1:2022"
KOKORO_URL = "http://127.0.0.1:8880"

# Deployment modes: "local" (all on this machine), "split" (hub local, TTS/STT remote),
# "remote" (thin client — hub, TTS, STT all remote)
DEPLOYMENT_MODE = "local"

# Quality mode maps to Whisper model sizes: "high" = large-v3, "medium" = medium, "low" = tiny
QUALITY_MODE = "high"
QUALITY_MODEL_MAP = {
    "high": "large-v3",
    "medium": "medium",
    "low": "tiny",
}

# Default project voices (9 agents)
VOICES = [
    ("af_sky", "Sky"),
    ("af_alloy", "Alloy"),
    ("af_sarah", "Sarah"),
    ("am_adam", "Adam"),
    ("am_echo", "Echo"),
    ("am_onyx", "Onyx"),
    ("bm_fable", "Fable"),
    ("af_nova", "Nova"),
    ("am_eric", "Eric"),
]

AGENTS_PER_PROJECT = 9

# Full English voice pool for multi-project support (27 voices = 3 projects of 9)
# Grouped in sets of 9 for project assignment
VOICE_POOL = [
    # Project 1 (default) — original 7 + Nova + Eric
    ("af_sky", "Sky"),
    ("af_alloy", "Alloy"),
    ("af_sarah", "Sarah"),
    ("am_adam", "Adam"),
    ("am_echo", "Echo"),
    ("am_onyx", "Onyx"),
    ("bm_fable", "Fable"),
    ("af_nova", "Nova"),
    ("am_eric", "Eric"),
    # Project 2
    ("af_bella", "Bella"),
    ("af_jessica", "Jessica"),
    ("af_heart", "Heart"),
    ("am_michael", "Michael"),
    ("am_liam", "Liam"),
    ("am_fenrir", "Fenrir"),
    ("bf_emma", "Emma"),
    ("bm_george", "George"),
    ("bm_daniel", "Daniel"),
    # Project 3
    ("af_aoede", "Aoede"),
    ("af_jadzia", "Jadzia"),
    ("af_kore", "Kore"),
    ("af_nicole", "Nicole"),
    ("af_river", "River"),
    ("am_puck", "Puck"),
    ("bf_alice", "Alice"),
    ("bf_lily", "Lily"),
    ("bm_lewis", "Lewis"),
]
