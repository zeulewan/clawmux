#!/bin/bash
# Start hub.py — kills any existing instances first to prevent duplicates
cd "$(dirname "$0")"
pids=$(pgrep -f "python.*hub\.py" 2>/dev/null)
if [ -n "$pids" ]; then
  echo "Stopping existing hub (PIDs: $pids)"
  kill -9 $pids
  sleep 1
fi
echo "Starting hub.py..."
.venv/bin/python server/hub.py >> /tmp/voice-hub.log 2>&1 &
echo "Started PID $!"
