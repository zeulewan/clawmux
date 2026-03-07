#!/bin/bash
# Stop the Kokoro TTS server
CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
KOKORO_DIR="$CLAWMUX_HOME/services/kokoro"
PID_FILE="$KOKORO_DIR/kokoro.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "[kokoro] Stopped (PID $PID)"
    else
        echo "[kokoro] PID $PID not running"
    fi
    rm -f "$PID_FILE"
else
    # Fallback: find by process name
    PIDS=$(pgrep -f "uvicorn.*kokoro" 2>/dev/null)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill
        echo "[kokoro] Stopped (PIDs: $PIDS)"
    else
        echo "[kokoro] Not running"
    fi
fi
