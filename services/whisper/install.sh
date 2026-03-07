#!/bin/bash
# Install whisper.cpp server and download models for ClawMux STT
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
WHISPER_DIR="$CLAWMUX_HOME/services/whisper"
MODEL_DIR="$WHISPER_DIR/models"
DEFAULT_MODEL="${CLAWMUX_WHISPER_MODEL:-large-v3}"

info()  { echo -e "\033[1;34m[whisper]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[whisper]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[whisper]\033[0m $*"; }
error() { echo -e "\033[1;31m[whisper]\033[0m $*"; }

mkdir -p "$WHISPER_DIR" "$MODEL_DIR"

# --- Build whisper.cpp ---
if [ -f "$WHISPER_DIR/build/bin/whisper-server" ]; then
    ok "whisper-server binary already exists"
else
    info "Cloning whisper.cpp..."
    WHISPER_SRC="$(mktemp -d)"
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_SRC"

    info "Building whisper-server..."
    cd "$WHISPER_SRC"

    # Detect CUDA
    if command -v nvcc &>/dev/null || [ -d /usr/local/cuda ]; then
        info "CUDA detected — building with GPU support"
        cmake -B build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=OFF
    else
        info "No CUDA — building CPU-only"
        cmake -B build -DBUILD_SHARED_LIBS=OFF
    fi

    cmake --build build --config Release -j "$(nproc 2>/dev/null || echo 4)" --target whisper-server

    # Copy binary and models dir structure
    mkdir -p "$WHISPER_DIR/build/bin"
    cp build/bin/whisper-server "$WHISPER_DIR/build/bin/"

    cd - >/dev/null
    rm -rf "$WHISPER_SRC"
    ok "whisper-server built successfully"
fi

# --- Download model ---
MODEL_FILE="$MODEL_DIR/ggml-${DEFAULT_MODEL}.bin"
if [ -f "$MODEL_FILE" ]; then
    ok "Model ggml-${DEFAULT_MODEL}.bin already exists"
else
    info "Downloading ggml-${DEFAULT_MODEL}.bin..."
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${DEFAULT_MODEL}.bin"
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    if [ -f "$MODEL_FILE" ] && [ -s "$MODEL_FILE" ]; then
        ok "Model downloaded: ggml-${DEFAULT_MODEL}.bin"
    else
        error "Model download failed"
        rm -f "$MODEL_FILE"
        exit 1
    fi
fi

ok "Whisper installation complete"
echo "  Binary: $WHISPER_DIR/build/bin/whisper-server"
echo "  Model:  $MODEL_FILE"
