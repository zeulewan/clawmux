#!/bin/bash
# ClawMux Stop Hook — Check inbox for pending messages.
#
# Called by Claude Code when it finishes responding (Stop event).
# - If inbox has messages: reads them, outputs to stderr, exits 2
#   (exit 2 on Stop prevents Claude from stopping → continues conversation)
# - If inbox is empty: exits 0 (Claude stops normally, agent goes idle)
#
# Requires: CLAWMUX_SESSION_ID and CLAWMUX_PORT env vars.

set -euo pipefail

# Skip if not in a ClawMux session
[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

# Read and clear inbox via hub API
RESPONSE=$(curl -sf "http://localhost:${CLAWMUX_PORT}/api/inbox/${CLAWMUX_SESSION_ID}" 2>/dev/null) || exit 0

# Parse messages array
MESSAGES=$(echo "$RESPONSE" | jq -r '.messages // []')
COUNT=$(echo "$MESSAGES" | jq 'length')

# No messages → prompt agent to enter idle mode
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
            "[VOICE from:\(.from)] \(.content)"
        else
            "[SYSTEM] \(.content)"
        end'
} >&2

# Exit 2 = blocking error for Stop hook → prevents Claude from stopping,
# stderr content is fed back to Claude as context
exit 2
