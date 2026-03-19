"""Hub configuration constants."""

import os
import secrets
import time
from pathlib import Path

# Base directory for all ClawMux data (sessions, agents.json, history)
CLAWMUX_HOME = Path(os.environ.get("CLAWMUX_HOME", os.path.expanduser("~/.clawmux")))
SESSIONS_DIR = CLAWMUX_HOME / "sessions"
DATA_DIR = CLAWMUX_HOME / "data"


# Legacy session directory (pre-v0.7.3) — scanned for orphan adoption
LEGACY_SESSION_DIR = Path("/tmp/clawmux-sessions")

HUB_PORT = int(os.environ.get("CLAWMUX_PORT", "3460"))

# External sender token — allows authorized external systems (e.g. OpenClaw) to send
# messages to ClawMux agents without being a registered session.
# Generated once per hub lifetime and written to ~/.clawmux/data/external_token.
def _load_or_create_external_token() -> str:
    token_path = DATA_DIR / "external_token"
    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        if token_path.exists():
            return token_path.read_text().strip()
        token = secrets.token_hex(32)
        token_path.write_text(token)
        token_path.chmod(0o600)
        return token
    except OSError:
        return secrets.token_hex(32)  # ephemeral fallback

EXTERNAL_TOKEN = _load_or_create_external_token()
HUB_START_TIME = time.time()
SESSION_TIMEOUT_MINUTES = int(os.environ.get("VOICE_CHAT_TIMEOUT", "0"))  # 0 = never timeout
HEALTH_CHECK_INTERVAL_SECONDS = 15
CLAUDE_BASE_COMMAND = "claude --dangerously-skip-permissions"
CLAUDE_MODEL = os.environ.get("VOICE_CHAT_MODEL", "opus")  # opus, sonnet, haiku
CLAUDE_EFFORT = os.environ.get("CLAWMUX_EFFORT", "high")  # low, medium, high
DEFAULT_BACKEND = "claude-code"  # default backend for new sessions
OPENCLAW_GATEWAY_URL = os.environ.get("OPENCLAW_GATEWAY_URL", "ws://127.0.0.1:18789")
# Token: env var first, then read from OpenClaw's own config
def _read_openclaw_token() -> str:
    env = os.environ.get("OPENCLAW_GATEWAY_TOKEN", "")
    if env:
        return env
    try:
        import json as _json
        p = Path.home() / ".openclaw" / "openclaw.json"
        if p.exists():
            return _json.loads(p.read_text()).get("gateway", {}).get("auth", {}).get("token", "")
    except Exception:
        pass
    return ""
OPENCLAW_GATEWAY_TOKEN = _read_openclaw_token()
TMUX_SESSION_PREFIX = "voice"
WHISPER_URL = "http://127.0.0.1:2022"
KOKORO_URL = "http://127.0.0.1:8880"

# Quality mode maps to Whisper model sizes: "high" = large-v3, "medium" = medium, "low" = base
QUALITY_MODE = "high"
QUALITY_MODEL_MAP = {
    "high": "large-v3",
    "medium": "medium",
    "low": "base",
}

# Whisper model file paths (for dynamic loading via /load endpoint)
# Resolved at runtime based on common install locations
WHISPER_MODEL_DIR = os.path.expanduser(
    os.environ.get("CLAWMUX_WHISPER_MODEL_DIR", str(CLAWMUX_HOME / "services" / "whisper" / "models"))
)

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

# Tmux status bar colors per voice (used for agent session styling)
AGENT_COLORS = {
    # Project 1 (default)
    "af_sky": "colour33",      # blue
    "af_alloy": "colour208",   # orange
    "af_sarah": "colour196",   # red
    "am_adam": "colour78",     # green
    "am_echo": "colour134",    # purple
    "am_onyx": "colour245",    # grey
    "bm_fable": "colour220",   # yellow
    "af_nova": "colour213",    # pink
    "am_eric": "colour39",     # cyan
    # Project 2
    "af_bella": "colour171",   # lavender
    "af_jessica": "colour209", # coral
    "af_heart": "colour204",   # rose
    "am_michael": "colour70",  # forest green
    "am_liam": "colour67",     # steel blue
    "am_fenrir": "colour130",  # brown
    "bf_emma": "colour174",    # salmon
    "bm_george": "colour109",  # teal
    "bm_daniel": "colour137",  # tan
    # Project 3
    "af_aoede": "colour183",   # light purple
    "af_jadzia": "colour117",  # light blue
    "af_kore": "colour168",    # magenta
    "af_nicole": "colour216",  # peach
    "af_river": "colour73",    # aqua
    "am_puck": "colour142",    # olive
    "bf_alice": "colour182",   # mauve
    "bf_lily": "colour223",    # cream
    "bm_lewis": "colour101",   # khaki
}
