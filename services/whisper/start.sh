#!/bin/bash
# Start the shared whisper.cpp server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/shared-paths.sh"

mkdir -p "$LOG_DIR" "$WHISPER_DIR"

# Already running?
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[whisper] Already running (PID $(cat "$PID_FILE"))"
  exit 0
fi

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

nohup "$SERVER_BIN" \
  --host 127.0.0.1 \
  --port "$WHISPER_PORT" \
  --model "$MODEL_PATH" \
  --inference-path /v1/audio/transcriptions \
  --threads "$THREADS" \
  --convert \
  >> "$LOG_DIR/whisper.log" 2>&1 &

echo $! > "$PID_FILE"
echo "[whisper] Started (PID $!)"
