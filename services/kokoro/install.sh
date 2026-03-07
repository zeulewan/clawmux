#!/bin/bash
# Install Kokoro TTS server for ClawMux
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
KOKORO_DIR="$CLAWMUX_HOME/services/kokoro"

info()  { echo -e "\033[1;34m[kokoro]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[kokoro]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[kokoro]\033[0m $*"; }
error() { echo -e "\033[1;31m[kokoro]\033[0m $*"; }

mkdir -p "$KOKORO_DIR"

# --- Clone Kokoro FastAPI ---
if [ -d "$KOKORO_DIR/api" ] && [ -f "$KOKORO_DIR/api/pyproject.toml" ]; then
    ok "Kokoro API already cloned"
    info "Pulling latest..."
    cd "$KOKORO_DIR"
    git pull --ff-only 2>/dev/null || warn "Could not pull latest (offline or detached HEAD)"
    cd - >/dev/null
else
    info "Cloning Kokoro FastAPI..."
    # Clone into a temp dir then move, since KOKORO_DIR may already exist
    KOKORO_TMP="$(mktemp -d)"
    git clone --depth 1 https://github.com/remsky/Kokoro-FastAPI.git "$KOKORO_TMP"
    # Move contents into KOKORO_DIR
    if [ -d "$KOKORO_DIR" ]; then
        cp -r "$KOKORO_TMP/." "$KOKORO_DIR/"
    else
        mv "$KOKORO_TMP" "$KOKORO_DIR"
    fi
    rm -rf "$KOKORO_TMP"
    ok "Kokoro API cloned"
fi

# --- Set up Python venv ---
if [ -d "$KOKORO_DIR/.venv" ] && [ -f "$KOKORO_DIR/.venv/bin/python" ]; then
    ok "Python venv already exists"
else
    info "Creating Python venv..."
    python3 -m venv "$KOKORO_DIR/.venv"
    ok "Venv created"
fi

info "Installing dependencies..."
"$KOKORO_DIR/.venv/bin/pip" install -q -e "$KOKORO_DIR/api" 2>&1 | tail -5

# Check for CUDA and install appropriate torch
if command -v nvcc &>/dev/null || [ -d /usr/local/cuda ]; then
    info "CUDA detected — ensuring GPU torch is installed"
    "$KOKORO_DIR/.venv/bin/pip" install -q torch --index-url https://download.pytorch.org/whl/cu121 2>&1 | tail -3
fi

ok "Kokoro installation complete"
echo "  Directory: $KOKORO_DIR"
echo "  Venv:      $KOKORO_DIR/.venv"
