#!/bin/bash
# ClawMux Installer
# Detects hardware, installs dependencies, sets up TTS/STT, and configures the hub.
# Usage: curl -sSL https://raw.githubusercontent.com/zeulewan/clawmux/main/install.sh | bash
#   or:  ./install.sh

set -euo pipefail

REPO_URL="https://github.com/zeulewan/clawmux.git"
INSTALL_DIR="${CLAWMUX_DIR:-$HOME/GIT/clawmux}"
HUB_PORT="${CLAWMUX_PORT:-3460}"
WHISPER_PORT=2022
KOKORO_PORT=8880

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# --- Hardware Detection ---

detect_gpu() {
    if command -v nvidia-smi &>/dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
        if [ -n "$GPU_NAME" ]; then
            echo "nvidia"
            return
        fi
    fi
    if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Apple M"; then
        echo "apple"
        return
    fi
    echo "none"
}

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

# --- Preflight Checks ---

echo ""
echo "========================================="
echo "  ClawMux Installer"
echo "========================================="
echo ""

OS=$(detect_os)
GPU=$(detect_gpu)

info "OS: $OS"
info "GPU: $GPU ${GPU_NAME:+($GPU_NAME, ${GPU_VRAM}MB VRAM)}"

# Check Python
if ! command -v python3 &>/dev/null; then
    fail "Python 3 is required. Install it first."
fi
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
info "Python: $PYTHON_VERSION"

# Check tmux
if ! command -v tmux &>/dev/null; then
    warn "tmux not found. Installing..."
    if [ "$OS" = "linux" ]; then
        sudo apt-get update && sudo apt-get install -y tmux
    elif [ "$OS" = "macos" ]; then
        brew install tmux
    fi
fi
ok "tmux installed"

# Check Claude Code
if command -v claude &>/dev/null; then
    ok "Claude Code installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
else
    warn "Claude Code not found. Install from https://claude.com/claude-code"
    warn "Continuing anyway — you can install Claude Code later."
fi

# --- Clone / Update Repo ---

if [ -d "$INSTALL_DIR/.git" ]; then
    info "Repo already exists at $INSTALL_DIR, pulling latest..."
    cd "$INSTALL_DIR"
    git pull --ff-only || warn "Could not pull latest (you may have local changes)"
else
    info "Cloning repo to $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# --- Python Venv & Dependencies ---

if [ ! -d ".venv" ]; then
    info "Creating Python virtual environment..."
    python3 -m venv .venv
fi
source .venv/bin/activate
info "Installing Python dependencies..."
pip install -q -r requirements.txt
ok "Python dependencies installed"

# --- TTS/STT Setup ---

install_nvidia_services() {
    info "Setting up TTS/STT for NVIDIA GPU..."

    # Check if voicemode is available
    if ! command -v voicemode &>/dev/null && ! pip show voicemode &>/dev/null; then
        info "Installing VoiceMode for TTS/STT service management..."
        pip install -q voicemode || pipx install voicemode || {
            warn "Could not install voicemode. Install TTS/STT manually."
            return
        }
    fi

    # Whisper STT
    if curl -s "http://127.0.0.1:$WHISPER_PORT/v1/models" &>/dev/null; then
        ok "Whisper STT already running on port $WHISPER_PORT"
    else
        info "Installing Whisper STT..."
        voicemode whisper install 2>/dev/null || warn "Whisper install failed — install manually"
        voicemode whisper start 2>/dev/null || warn "Whisper start failed — start manually"
    fi

    # Kokoro TTS
    if curl -s "http://127.0.0.1:$KOKORO_PORT/v1/models" &>/dev/null; then
        ok "Kokoro TTS already running on port $KOKORO_PORT"
    else
        info "Installing Kokoro TTS..."
        voicemode kokoro install 2>/dev/null || warn "Kokoro install failed — install manually"
        voicemode kokoro start 2>/dev/null || warn "Kokoro start failed — start manually"
    fi
}

install_apple_services() {
    info "Setting up TTS/STT for Apple Silicon..."
    warn "Apple Silicon support requires mlx-audio (TTS) and whisper.cpp (STT)."
    warn "These need to be installed separately. See the deployment modes docs."
    # Future: automate mlx-audio and whisper.cpp installation
}

case "$GPU" in
    nvidia) install_nvidia_services ;;
    apple)  install_apple_services ;;
    none)
        warn "No GPU detected. ClawMux requires a GPU for TTS/STT."
        warn "You can use Split mode to point at a remote GPU server."
        warn "Set tts_url and stt_url in Settings after starting the hub."
        ;;
esac

# --- Install CLI ---

CLI_SRC="$INSTALL_DIR/clawmux"
CLI_DEST="/usr/local/bin/clawmux"

if [ -f "$CLI_SRC" ]; then
    info "Installing clawmux CLI..."
    sudo cp "$CLI_SRC" "$CLI_DEST" 2>/dev/null || {
        warn "Could not install to $CLI_DEST (no sudo). Adding to PATH instead."
        export PATH="$INSTALL_DIR:$PATH"
    }
    sudo chmod +x "$CLI_DEST" 2>/dev/null || true
    # Rewrite shebang to use project venv python
    sudo sed -i'' -e "1s|.*|#!${INSTALL_DIR}/.venv/bin/python3|" "$CLI_DEST" 2>/dev/null || true
    ok "clawmux CLI installed"
else
    warn "CLI not found at $CLI_SRC — skipping CLI install"
fi

# --- Install Slash Commands ---

if command -v claude &>/dev/null; then
    # Install slash commands
    mkdir -p ~/.claude/commands
    if [ -f "$INSTALL_DIR/.claude/commands/clawmux.md" ]; then
        cp "$INSTALL_DIR/.claude/commands/clawmux.md" ~/.claude/commands/clawmux.md
        ok "Slash commands installed"
    fi
fi

# --- Install Claude Code Hooks ---

if command -v claude &>/dev/null; then
    info "Configuring Claude Code hooks..."
    python3 -c "
import json, os
settings_path = os.path.expanduser('~/.claude/settings.json')
os.makedirs(os.path.dirname(settings_path), exist_ok=True)
try:
    with open(settings_path) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    d = {}

hook = {'hooks': [{'type': 'http', 'url': 'http://localhost:${HUB_PORT}/api/hooks/tool-status', 'timeout': 5, 'headers': {'X-ClawMux-Session': '\$CLAWMUX_SESSION_ID'}, 'allowedEnvVars': ['CLAWMUX_SESSION_ID']}]}
stop_hook = {'hooks': [{'type': 'command', 'command': '${INSTALL_DIR}/hooks/stop-check-inbox.sh', 'timeout': 10, 'allowedEnvVars': ['CLAWMUX_SESSION_ID', 'CLAWMUX_PORT']}]}
d['hooks'] = {'PreToolUse': [hook], 'PostToolUse': [hook], 'PostToolUseFailure': [hook], 'PreCompact': [hook], 'Stop': [stop_hook]}
with open(settings_path, 'w') as f:
    json.dump(d, f, indent=2)
print('done')
" && ok "Claude Code hooks configured" || warn "Could not configure hooks"
fi

# --- Tailscale HTTPS (optional) ---

if command -v tailscale &>/dev/null; then
    TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('Self',{}).get('DNSName',''))" 2>/dev/null || echo "")
    if [ -n "$TAILSCALE_STATUS" ]; then
        ok "Tailscale active: $TAILSCALE_STATUS"
        info "To enable remote HTTPS access, run:"
        info "  sudo tailscale serve --bg --https=$HUB_PORT http://127.0.0.1:$HUB_PORT"
    fi
else
    info "Tailscale not installed. Optional for remote access."
fi

# --- Done ---

echo ""
echo "========================================="
echo "  Installation Complete"
echo "========================================="
echo ""
echo "  Start the hub:"
echo "    cd $INSTALL_DIR && ./start-hub.sh"
echo ""
echo "  Or with tmux:"
echo "    tmux new-session -d -s clawmux 'cd $INSTALL_DIR && ./start-hub.sh'"
echo ""
echo "  Open in browser:"
echo "    http://localhost:$HUB_PORT"
echo ""
if command -v tailscale &>/dev/null; then
echo "  Remote access (after tailscale serve):"
echo "    https://$(hostname).ts.net:$HUB_PORT"
echo ""
fi
echo "  Deployment mode: ${GPU} (change in Settings)"
echo ""
