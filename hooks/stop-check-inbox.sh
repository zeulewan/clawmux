#!/bin/bash
# ClawMux Stop Hook — Signal idle state to hub for tmux-push message delivery.
#
# Called by Claude Code when it finishes responding (Stop event).
# Exit 2 prevents Claude from stopping; stderr content is fed back as context.
#
# Priority order:
# 1. If hub delivered a message via hooks during this work cycle (.hook_delivered
#    sentinel file exists) → tell Claude to process it, don't go idle.
# 2. Signal hub that agent is now idle (POST /api/agents/{id}/idle).
#    Hub will inject any pending inbox messages via tmux after a short delay.
# 3. Exit 0 — agent stops; hub handles wake-up.
#
# Requires: CLAWMUX_SESSION_ID and CLAWMUX_PORT env vars.

set -euo pipefail

# Skip if not in a ClawMux session
[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

# CLAWMUX_WORK_DIR is the canonical voice_id-based session directory.
# CLAWMUX_SESSION_ID is the shorter label (e.g. "sky" vs "af_sky").
WORK_DIR="${CLAWMUX_WORK_DIR:-${HOME}/.clawmux/sessions/${CLAWMUX_SESSION_ID}}"
SENTINEL="${WORK_DIR}/.hook_delivered"

# Check if a message was already delivered via hooks this cycle
if [ -f "$SENTINEL" ]; then
    rm -f "$SENTINEL"
    echo "A message was delivered to you via hooks during your last task (look for [MSG] or [VOICE] in system reminders above). If you already responded to it, you are done — stop here. If you have not responded yet, do so now." >&2
    exit 2
fi

# Signal hub that agent is now idle — hub will inject pending inbox messages via tmux
curl -sf -X POST "http://localhost:${CLAWMUX_PORT}/api/agents/${CLAWMUX_SESSION_ID}/idle" \
    -H "Content-Type: application/json" \
    -d '{}' >/dev/null 2>&1 || true

# Exit 0: agent stops naturally; hub wakes it up when a message arrives
exit 0
