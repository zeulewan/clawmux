#!/bin/bash
# ClawMux Stop Hook — Check for pending messages and direct Claude accordingly.
#
# Called by Claude Code when it finishes responding (Stop event).
# Exit 2 prevents Claude from stopping; stderr content is fed back as context.
#
# Priority order:
# 1. If hub delivered a message via hooks during this work cycle (.hook_delivered
#    sentinel file exists) → tell Claude to process it, don't go idle.
# 2. If inbox has new messages (arrived after last hook delivery) → deliver them.
# 3. No messages → check .waiting PID sentinel (written by clawmux wait on startup).
#    If the wait process is alive, exit 0 (it will receive messages). Otherwise exit 2.
#
# Requires: CLAWMUX_SESSION_ID and CLAWMUX_PORT env vars.

set -euo pipefail

# Skip if not in a ClawMux session
[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

# CLAWMUX_WORK_DIR is the canonical voice_id-based session directory.
# CLAWMUX_SESSION_ID is the shorter label (e.g. "sky" vs "af_sky").
# Fall back to label-based path only for backwards compatibility.
WORK_DIR="${CLAWMUX_WORK_DIR:-${HOME}/.clawmux/sessions/${CLAWMUX_SESSION_ID}}"
SENTINEL="${WORK_DIR}/.hook_delivered"

# Check if a message was already delivered via hooks this cycle
if [ -f "$SENTINEL" ]; then
    rm -f "$SENTINEL"
    echo "A message was delivered to you via hooks during your last task (look for [MSG] or [VOICE] in system reminders above). If you already responded to it, run \`clawmux wait\` now. If you have not responded yet, do so now, then run \`clawmux wait\`." >&2
    exit 2
fi

# Read and clear inbox via hub API
RESPONSE=$(curl -sf "http://localhost:${CLAWMUX_PORT}/api/inbox/${CLAWMUX_SESSION_ID}" 2>/dev/null) || {
    exit 0
}

# Parse messages array
MESSAGES=$(echo "$RESPONSE" | jq -r '.messages // []')
COUNT=$(echo "$MESSAGES" | jq 'length')

# No messages → check if a clawmux wait process is already running via PID sentinel.
# clawmux wait writes ~/.clawmux/sessions/{ID}/.waiting containing its PID on startup,
# before the WebSocket connects. A live PID means wait will receive incoming messages.
#
# Background tasks in Claude Code start AFTER the stop hook fires, so we retry briefly
# to give a freshly-spawned clawmux wait process time to write its sentinel file.
if [ "$COUNT" = "0" ]; then
    SENTINEL_WAIT="${WORK_DIR}/.waiting"
    # Retry up to 20 times (2s total) to handle race with background task startup
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [ -f "$SENTINEL_WAIT" ]; then
            WAIT_PID=$(cat "$SENTINEL_WAIT" 2>/dev/null)
            if [ -n "$WAIT_PID" ] && kill -0 "$WAIT_PID" 2>/dev/null; then
                exit 0  # wait process is alive; it will receive any incoming messages
            else
                rm -f "$SENTINEL_WAIT"  # stale sentinel (process crashed/killed), clean up
                break
            fi
        fi
        sleep 0.1
    done
    echo "No pending messages. Run \`clawmux wait\` to enter idle mode and receive messages." >&2
    exit 2
fi

# Format messages for Claude's context (stderr on exit 2 is fed to Claude)
{
    echo "You have ${COUNT} new message(s):"
    echo ""
    echo "$MESSAGES" | jq -r '.[] |
        if .type == "agent" then
            "[MSG id:\(.id) from:\(.from)] \(.content)"
        elif .type == "voice" then
            "[VOICE id:\(.id) from:\(.from)] \(.content)"
        else
            "[SYSTEM] \(.content)"
        end'
    echo ""
    echo "Process these messages now. Do NOT call clawmux wait."
} >&2

# Exit 2 = blocking error for Stop hook → prevents Claude from stopping,
# stderr content is fed back to Claude as context
exit 2
