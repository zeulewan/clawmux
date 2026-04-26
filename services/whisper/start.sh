#!/bin/bash
# Start whisper.cpp server for ClawMux STT
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
WHISPER_DIR="$CLAWMUX_HOME/services/whisper"
WHISPER_PORT="${CLAWMUX_WHISPER_PORT:-2022}"
WHISPER_MODEL="${CLAWMUX_WHISPER_MODEL:-large-v3}"
MODEL_PATH="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"
LOG_DIR="$CLAWMUX_HOME/logs"
PID_FILE="$WHISPER_DIR/whisper.pid"

mkdir -p "$LOG_DIR"

# Already running?
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[whisper] Already running (PID $(cat "$PID_FILE"))"
  exit 0
fi

SERVER_BIN="$WHISPER_DIR/build/bin/whisper-server"
if [ ! -f "$SERVER_BIN" ]; then
  echo "[whisper] Error: whisper-server binary not found. Run install.sh first."
  exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
  FALLBACK=$(ls "$WHISPER_DIR/models/"ggml-*.bin 2>/dev/null | head -1)
  if [ -n "$FALLBACK" ]; then
    MODEL_PATH="$FALLBACK"
    echo "[whisper] Warning: ${WHISPER_MODEL} not found, using $(basename "$FALLBACK")"
  else
    echo "[whisper] Error: No models found. Run install.sh first."
    exit 1
  fi
fi

THREADS=$(nproc 2>/dev/null || echo 4)
echo "[whisper] Starting on port $WHISPER_PORT with model $(basename "$MODEL_PATH") ($THREADS threads)"

export LD_LIBRARY_PATH="$WHISPER_DIR/build/src:$WHISPER_DIR/build/ggml/src:$WHISPER_DIR/build/ggml/src/ggml-cuda:${LD_LIBRARY_PATH:-}"

nohup "$SERVER_BIN" \
  --host 0.0.0.0 \
  --port "$WHISPER_PORT" \
  --model "$MODEL_PATH" \
  --inference-path /v1/audio/transcriptions \
  --threads "$THREADS" \
  --convert \
  >> "$LOG_DIR/whisper.log" 2>&1 &

echo $! > "$PID_FILE"
echo "[whisper] Started (PID $!)"
