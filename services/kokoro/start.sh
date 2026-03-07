#!/bin/bash
# Start the Kokoro TTS server for ClawMux
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
KOKORO_DIR="$CLAWMUX_HOME/services/kokoro"
KOKORO_PORT="${CLAWMUX_KOKORO_PORT:-8880}"
LOG_DIR="$CLAWMUX_HOME/logs"

mkdir -p "$LOG_DIR"

# Check if already running
if curl -s "http://127.0.0.1:${KOKORO_PORT}/v1/models" &>/dev/null; then
    echo "[kokoro] Already running on port $KOKORO_PORT"
    exit 0
fi

# Check installation
if [ ! -d "$KOKORO_DIR/.venv" ] || [ ! -d "$KOKORO_DIR/api" ]; then
    echo "[kokoro] Error: Kokoro not installed. Run install.sh first."
    exit 1
fi

echo "[kokoro] Starting on port $KOKORO_PORT..."

cd "$KOKORO_DIR"
MODEL_DIR="$KOKORO_DIR/api/src/models" VOICES_DIR="$KOKORO_DIR/api/src/voices/v1_0" KOKORO_HOST=0.0.0.0 KOKORO_PORT="$KOKORO_PORT" \
    nohup "$KOKORO_DIR/.venv/bin/python" -m uvicorn api.src.main:app \
    --host 0.0.0.0 --port "$KOKORO_PORT" \
    >> "$LOG_DIR/kokoro.log" 2>&1 &

echo $! > "$KOKORO_DIR/kokoro.pid"
echo "[kokoro] Started (PID $!)"
