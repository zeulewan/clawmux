#!/bin/bash
# Install whisper.cpp as a shared workstation STT service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/shared-paths.sh"

DEFAULT_MODEL="$WHISPER_MODEL"

info()  { echo -e "\033[1;34m[whisper]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[whisper]\033[0m $*"; }
error() { echo -e "\033[1;31m[whisper]\033[0m $*"; }

mkdir -p "$WHISPER_DIR" "$MODEL_DIR" "$BIN_DIR" "$BUILD_BIN_DIR" "$LOG_DIR" "$(dirname "$VOICEMODE_ENV")"

migrate_legacy_install() {
  if [ ! -d "$LEGACY_WHISPER_DIR" ] || [ "$LEGACY_WHISPER_DIR" = "$WHISPER_DIR" ]; then
    return
  fi

  if [ -f "$LEGACY_WHISPER_DIR/build/bin/whisper-server" ] && [ ! -f "$SERVER_BIN" ]; then
    info "Migrating whisper-server out of $LEGACY_WHISPER_DIR"
    mv "$LEGACY_WHISPER_DIR/build/bin/whisper-server" "$SERVER_BIN"
  fi

  shopt -s nullglob
  for model in "$LEGACY_WHISPER_DIR"/models/ggml-*.bin; do
    target="$MODEL_DIR/$(basename "$model")"
    if [ ! -f "$target" ]; then
      info "Migrating $(basename "$model") out of $LEGACY_WHISPER_DIR"
      mv "$model" "$target"
    fi
  done
  shopt -u nullglob
}

install_start_script() {
  cp "$SCRIPT_DIR/start.sh" "$BIN_DIR/start-whisper-server.sh"
  cp "$SCRIPT_DIR/shared-paths.sh" "$BIN_DIR/shared-paths.sh"
  chmod +x "$BIN_DIR/start-whisper-server.sh"
}

ensure_voicemode_env() {
  touch "$VOICEMODE_ENV"
  if ! grep -q '^VOICEMODE_WHISPER_MODEL=' "$VOICEMODE_ENV" 2>/dev/null; then
    printf 'VOICEMODE_WHISPER_MODEL=%s\n' "$DEFAULT_MODEL" >> "$VOICEMODE_ENV"
  fi
  if ! grep -q '^VOICEMODE_WHISPER_PORT=' "$VOICEMODE_ENV" 2>/dev/null; then
    printf 'VOICEMODE_WHISPER_PORT=%s\n' "$WHISPER_PORT" >> "$VOICEMODE_ENV"
  fi
}

install_systemd_unit() {
  local unit_dir="$HOME/.config/systemd/user"
  local unit_path="$unit_dir/$SYSTEMD_UNIT_NAME"
  mkdir -p "$unit_dir"

  cat > "$unit_path" <<EOF
[Unit]
Description=Whisper.cpp Speech Recognition Server
After=network.target

[Service]
Type=forking
ExecStart=$BIN_DIR/start-whisper-server.sh
ExecStop=/bin/kill -TERM \$MAINPID
WorkingDirectory=$WHISPER_DIR
PIDFile=$PID_FILE
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=127
Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/cuda/bin"
StandardOutput=journal
StandardError=journal
SyslogIdentifier=voicemode-whisper

[Install]
WantedBy=default.target
EOF
}

migrate_legacy_install

# Build whisper-server binary
if [ -f "$SERVER_BIN" ]; then
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

  cp build/bin/whisper-server "$SERVER_BIN"
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

install_start_script
ensure_voicemode_env
install_systemd_unit

systemctl --user daemon-reload
systemctl --user enable --now "$SYSTEMD_UNIT_NAME" >/dev/null

ok "Done — binary: $SERVER_BIN"
ok "      model:  $MODEL_FILE"
ok "      unit:   $SYSTEMD_UNIT_NAME"
