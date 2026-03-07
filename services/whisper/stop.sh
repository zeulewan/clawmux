#!/bin/bash
# Stop the whisper.cpp server
CLAWMUX_HOME="${CLAWMUX_HOME:-$HOME/.clawmux}"
WHISPER_DIR="$CLAWMUX_HOME/services/whisper"
PID_FILE="$WHISPER_DIR/whisper.pid"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        echo "[whisper] Stopped (PID $PID)"
    else
        echo "[whisper] PID $PID not running"
    fi
    rm -f "$PID_FILE"
else
    # Fallback: find by process name
    PIDS=$(pgrep -f "whisper-server.*--port" 2>/dev/null)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill
        echo "[whisper] Stopped (PIDs: $PIDS)"
    else
        echo "[whisper] Not running"
    fi
fi
