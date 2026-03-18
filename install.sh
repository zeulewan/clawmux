#!/bin/bash
# ClawMux Installer
# Detects hardware, installs dependencies, sets up TTS/STT, and configures the hub.
# Usage: curl -sSL https://raw.githubusercontent.com/zeulewan/clawmux/main/install.sh | bash
#   or:  ./install.sh
#   or:  ./install.sh --force   (clean reinstall)

set -euo pipefail

REPO_URL="https://github.com/zeulewan/clawmux.git"

# Auto-detect install dir: use the directory this script lives in if it's a repo,
# otherwise fall back to CLAWMUX_DIR or clone from GitHub.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null || echo ".")" && pwd 2>/dev/null)"
if [ -d "$_self_dir/.git" ]; then
    INSTALL_DIR="${CLAWMUX_DIR:-$_self_dir}"
else
    INSTALL_DIR="${CLAWMUX_DIR:-$HOME/GIT/clawmux}"
fi
HUB_PORT="${CLAWMUX_PORT:-3460}"
WHISPER_PORT=2022
KOKORO_PORT=8880
FORCE=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
    esac
done

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

# Check Python — prefer Homebrew/newer python over system python
PYTHON3=""
for _p in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$_p" &>/dev/null; then
        _ver=$("$_p" -c "import sys; print(sys.version_info[:2] >= (3,10))" 2>/dev/null)
        if [ "$_ver" = "True" ]; then
            PYTHON3="$(command -v "$_p")"
            break
        fi
    fi
done
# Fall back to any python3 if no 3.10+ found
if [ -z "$PYTHON3" ]; then
    if command -v python3 &>/dev/null; then
        PYTHON3="$(command -v python3)"
        warn "Only found Python $($PYTHON3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") — 3.10+ is required."
        fail "Install Python 3.10+ (e.g. 'brew install python3') and re-run this script."
    else
        fail "Python 3 is required. Install it first."
    fi
fi
PYTHON_VERSION=$($PYTHON3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
info "Python: $PYTHON_VERSION ($PYTHON3)"

# Check tmux
if command -v tmux &>/dev/null; then
    ok "tmux installed"
else
    if [ "$OS" = "macos" ] && command -v brew &>/dev/null; then
        warn "tmux not found. Installing via Homebrew..."
        brew install tmux
        ok "tmux installed"
    else
        fail "tmux is required but not found. Please install it (e.g. 'apt install tmux' or 'brew install tmux') and re-run this script."
    fi
fi

# Check Claude Code
if command -v claude &>/dev/null; then
    ok "Claude Code installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
else
    warn "Claude Code not found. Install from https://claude.com/claude-code"
    warn "Continuing anyway — you can install Claude Code later."
fi

# --- Already Installed Detection ---

if [ -d "$INSTALL_DIR/.git" ]; then
    info "ClawMux is already installed at $INSTALL_DIR"
    cd "$INSTALL_DIR"

    # Check for updates
    git fetch --quiet 2>/dev/null || true
    UPDATES=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")

    if [ "$FORCE" = true ]; then
        warn "Force reinstall requested — removing venv and reinstalling..."
        rm -rf .venv
    elif [ "$UPDATES" -gt 0 ]; then
        info "Updates available ($UPDATES commits behind)."
        info "Run 'clawmux update' to update without reinstalling."
        read -p "Do you want to force a clean reinstall instead? (y/N): " REINSTALL
        if [[ "$REINSTALL" =~ ^[Yy] ]]; then
            warn "Clean reinstall — removing venv..."
            rm -rf .venv
        else
            info "Exiting. Run 'clawmux update' to pull the latest changes."
            exit 0
        fi
    else
        ok "Already installed and up to date."
        read -p "Do you want to force a clean reinstall? (y/N): " REINSTALL
        if [[ "$REINSTALL" =~ ^[Yy] ]]; then
            warn "Clean reinstall — removing venv..."
            rm -rf .venv
        else
            info "Nothing to do. Exiting."
            exit 0
        fi
    fi
else
    info "Cloning repo to $INSTALL_DIR..."
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# --- Python Venv & Dependencies ---

if [ ! -d ".venv" ]; then
    info "Creating Python virtual environment..."
    "$PYTHON3" -m venv .venv
fi
source .venv/bin/activate
info "Installing Python dependencies..."
pip install -q -r requirements.txt
ok "Python dependencies installed"

# --- TTS/STT Setup ---

install_nvidia_services() {
    info "Setting up TTS/STT for NVIDIA GPU..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Whisper STT
    if curl -s "http://127.0.0.1:$WHISPER_PORT/v1/models" &>/dev/null; then
        ok "Whisper STT already running on port $WHISPER_PORT"
    else
        info "Installing Whisper STT..."
        bash "$SCRIPT_DIR/services/whisper/install.sh" || warn "Whisper install failed — install manually"
        bash "$SCRIPT_DIR/services/whisper/start.sh" || warn "Whisper start failed — start manually"
    fi

    # Kokoro TTS
    if curl -s "http://127.0.0.1:$KOKORO_PORT/v1/models" &>/dev/null; then
        ok "Kokoro TTS already running on port $KOKORO_PORT"
    else
        info "Installing Kokoro TTS..."
        bash "$SCRIPT_DIR/services/kokoro/install.sh" || warn "Kokoro install failed — install manually"
        bash "$SCRIPT_DIR/services/kokoro/start.sh" || warn "Kokoro start failed — start manually"
    fi
}

install_apple_services() {
    info "Setting up TTS/STT for Apple Silicon..."
    warn "Apple Silicon support requires mlx-audio (TTS) and whisper.cpp (STT)."
    warn "These need to be installed separately. See the deployment modes docs."
    # Future: automate mlx-audio and whisper.cpp installation
}

case "$GPU" in
    nvidia)
        info "Found GPU: ${GPU_NAME:-NVIDIA} (${GPU_VRAM:-?}MB VRAM)"
        read -p "Install local TTS/STT services (Whisper + Kokoro)? (Y/n): " INSTALL_SERVICES
        INSTALL_SERVICES="${INSTALL_SERVICES:-Y}"
        if [[ "$INSTALL_SERVICES" =~ ^[Yy] ]]; then
            install_nvidia_services
        else
            info "Skipping local services. Configure remote TTS/STT URLs in Settings after starting the hub."
        fi
        ;;
    apple)
        info "Found Apple Silicon GPU"
        read -p "Install local TTS/STT services? (Y/n): " INSTALL_SERVICES
        INSTALL_SERVICES="${INSTALL_SERVICES:-Y}"
        if [[ "$INSTALL_SERVICES" =~ ^[Yy] ]]; then
            install_apple_services
        else
            info "Skipping local services. Configure remote TTS/STT URLs in Settings after starting the hub."
        fi
        ;;
    none)
        info "No GPU detected — configure remote TTS/STT in Settings after starting the hub."
        ;;
esac

# --- Install CLI ---

CLI_SRC="$INSTALL_DIR/clawmux"
LOCAL_BIN="$HOME/.local/bin"
CLI_DEST="$LOCAL_BIN/clawmux"

if [ -f "$CLI_SRC" ]; then
    info "Installing clawmux CLI..."
    chmod +x "$CLI_SRC"
    mkdir -p "$LOCAL_BIN"
    ln -sf "$CLI_SRC" "$CLI_DEST"
    ok "clawmux CLI installed → $CLI_DEST"

    # Check if ~/.local/bin is on PATH
    case ":$PATH:" in
        *":$LOCAL_BIN:"*) ;;
        *)
            warn "\$HOME/.local/bin is not on your PATH."
            SHELL_NAME="$(basename "$SHELL")"
            case "$SHELL_NAME" in
                zsh)  RC_FILE="~/.zshrc" ;;
                bash) RC_FILE="~/.bashrc" ;;
                fish) RC_FILE="~/.config/fish/config.fish" ;;
                *)    RC_FILE="your shell rc file" ;;
            esac
            info "Add it with:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> $RC_FILE"
            ;;
    esac
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

hook = {'hooks': [{'type': 'command', 'command': '${INSTALL_DIR}/hooks/tool-status.sh', 'timeout': 5, 'allowedEnvVars': ['CLAWMUX_SESSION_ID', 'CLAWMUX_PORT']}]}
stop_hook = {'hooks': [{'type': 'command', 'command': '${INSTALL_DIR}/hooks/stop-check-inbox.sh', 'timeout': 10, 'allowedEnvVars': ['CLAWMUX_SESSION_ID', 'CLAWMUX_PORT', 'CLAWMUX_WORK_DIR']}]}
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
