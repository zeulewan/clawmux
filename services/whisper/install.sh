#!/bin/bash
# Install whisper.cpp and download models for ClawMux STT
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
WHISPER_DIR="$CLAWMUX_HOME/services/whisper"
MODEL_DIR="$WHISPER_DIR/models"
DEFAULT_MODEL="${CLAWMUX_WHISPER_MODEL:-large-v3}"

info()  { echo -e "\033[1;34m[whisper]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[whisper]\033[0m $*"; }
error() { echo -e "\033[1;31m[whisper]\033[0m $*"; }

mkdir -p "$WHISPER_DIR" "$MODEL_DIR"

# Build whisper-server binary
if [ -f "$WHISPER_DIR/build/bin/whisper-server" ]; then
  ok "whisper-server binary already exists"
else
  info "Cloning whisper.cpp..."
  WHISPER_SRC=$(mktemp -d)
  git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$WHISPER_SRC"

  cd "$WHISPER_SRC"
  if command -v nvcc &>/dev/null; then
    info "CUDA detected — building with GPU support"
    cmake -B build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
  else
    info "No CUDA — building CPU-only"
    cmake -B build -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
  fi
  cmake --build build --config Release -j"$(nproc 2>/dev/null || echo 4)" --target whisper-server

  mkdir -p "$WHISPER_DIR/build/bin"
  cp build/bin/whisper-server "$WHISPER_DIR/build/bin/"
  cd - >/dev/null
  rm -rf "$WHISPER_SRC"
  ok "whisper-server built"
fi

# Download model
MODEL_FILE="$MODEL_DIR/ggml-${DEFAULT_MODEL}.bin"
if [ -f "$MODEL_FILE" ]; then
  ok "Model ggml-${DEFAULT_MODEL}.bin already exists"
else
  info "Downloading ggml-${DEFAULT_MODEL}.bin (~3GB)..."
  curl -L --progress-bar \
    -o "$MODEL_FILE" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${DEFAULT_MODEL}.bin"
  ok "Model downloaded"
fi

ok "Done — binary: $WHISPER_DIR/build/bin/whisper-server"
ok "      model:  $MODEL_FILE"
