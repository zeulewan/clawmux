#!/bin/bash
# Start the whisper.cpp server for ClawMux STT
set -e

CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
WHISPER_DIR="$CLAWMUX_HOME/services/whisper"
WHISPER_PORT="${CLAWMUX_WHISPER_PORT:-2022}"
WHISPER_MODEL="${CLAWMUX_WHISPER_MODEL:-large-v3}"
MODEL_PATH="$WHISPER_DIR/models/ggml-${WHISPER_MODEL}.bin"
LOG_DIR="$CLAWMUX_HOME/logs"

mkdir -p "$LOG_DIR"

# Check if already running
if curl -s "http://127.0.0.1:${WHISPER_PORT}/v1/models" &>/dev/null; then
    echo "[whisper] Already running on port $WHISPER_PORT"
    exit 0
fi

# Find binary
SERVER_BIN=""
if [ -f "$WHISPER_DIR/build/bin/whisper-server" ]; then
    SERVER_BIN="$WHISPER_DIR/build/bin/whisper-server"
else
    echo "[whisper] Error: whisper-server binary not found. Run install.sh first."
    exit 1
fi

# Check model
if [ ! -f "$MODEL_PATH" ]; then
    # Try fallback to any available model
    FALLBACK=$(ls "$WHISPER_DIR/models/"ggml-*.bin 2>/dev/null | head -1)
    if [ -n "$FALLBACK" ]; then
        MODEL_PATH="$FALLBACK"
        echo "[whisper] Warning: $WHISPER_MODEL not found, using $(basename "$FALLBACK")"
    else
        echo "[whisper] Error: No models found. Run install.sh first."
        exit 1
    fi
fi

# Detect thread count
if [ -n "${CLAWMUX_WHISPER_THREADS:-}" ]; then
    THREADS="$CLAWMUX_WHISPER_THREADS"
else
    THREADS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

echo "[whisper] Starting on port $WHISPER_PORT with model $(basename "$MODEL_PATH") ($THREADS threads)"

cd "$WHISPER_DIR"
export LD_LIBRARY_PATH="$WHISPER_DIR/build/src:$WHISPER_DIR/build/ggml/src:$WHISPER_DIR/build/ggml/src/ggml-cuda:${LD_LIBRARY_PATH:-}"
nohup "$SERVER_BIN" \
    --host 0.0.0.0 \
    --port "$WHISPER_PORT" \
    --model "$MODEL_PATH" \
    --inference-path /v1/audio/transcriptions \
    --threads "$THREADS" \
    --convert \
    >> "$LOG_DIR/whisper.log" 2>&1 &

echo $! > "$WHISPER_DIR/whisper.pid"
echo "[whisper] Started (PID $!)"
