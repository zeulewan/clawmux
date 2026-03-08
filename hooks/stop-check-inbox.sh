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
# 3. No messages → exit 2 with "run clawmux wait" (keeps Claude alive; wait WS sets state to IDLE).
#
# Requires: CLAWMUX_SESSION_ID and CLAWMUX_PORT env vars.

set -euo pipefail

# Skip if not in a ClawMux session
[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

WORK_DIR="${HOME}/.clawmux/sessions/${CLAWMUX_SESSION_ID}"
SENTINEL="${WORK_DIR}/.hook_delivered"

# Check if a message was already delivered via hooks this cycle
if [ -f "$SENTINEL" ]; then
    rm -f "$SENTINEL"
    echo "You received a message during your last task — it was delivered to you via hooks above. Scroll up, find it, and respond to it now. Do NOT call clawmux wait." >&2
    exit 2
fi

# Read and clear inbox via hub API
RESPONSE=$(curl -sf "http://localhost:${CLAWMUX_PORT}/api/inbox/${CLAWMUX_SESSION_ID}" 2>/dev/null) || {
    exit 0
}

# Parse messages array
MESSAGES=$(echo "$RESPONSE" | jq -r '.messages // []')
COUNT=$(echo "$MESSAGES" | jq 'length')

# No messages → tell Claude to run clawmux wait (keeps the loop alive via exit 2)
if [ "$COUNT" = "0" ]; then
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
