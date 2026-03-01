#!/bin/bash
# Stop all hub.py instances
pids=$(pgrep -f "python.*hub\.py" 2>/dev/null)
if [ -z "$pids" ]; then
  echo "Hub is not running."
else
  echo "Stopping hub (PIDs: $pids)"
  kill -9 $pids
  echo "Done."
fi
