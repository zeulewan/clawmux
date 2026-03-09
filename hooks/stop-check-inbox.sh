#!/bin/bash
# ClawMux Stop Hook — Signal idle state to hub for tmux-push message delivery.
#
# Called by Claude Code when it finishes responding (Stop event).
# Signals the hub that the agent is idle; hub injects any pending inbox messages
# via tmux after a short delay.
#
# Requires: CLAWMUX_SESSION_ID and CLAWMUX_PORT env vars.

set -euo pipefail

# Skip if not in a ClawMux session
[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

# Signal hub that agent is now idle — hub will inject pending inbox messages via tmux.
# Retry up to 3 times with 1s delay to handle hub reloads that may be mid-restart.
for i in 1 2 3; do
    curl -sf -X POST "http://localhost:${CLAWMUX_PORT}/api/agents/${CLAWMUX_SESSION_ID}/idle" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null 2>&1 && break
    sleep 1
done

exit 0
