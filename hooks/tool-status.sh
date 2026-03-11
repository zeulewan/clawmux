#!/bin/bash
# ClawMux tool-status hook — PreToolUse, PostToolUse, PostToolUseFailure, PreCompact.
#
# Forwards hook payload (stdin JSON) to the hub via HTTP.
# Silently exits if not running inside a ClawMux session.

set -euo pipefail

[ -z "${CLAWMUX_SESSION_ID:-}" ] && exit 0
[ -z "${CLAWMUX_PORT:-}" ] && exit 0

payload=$(cat)

curl -sf -X POST "http://localhost:${CLAWMUX_PORT}/api/hooks/tool-status" \
    -H "Content-Type: application/json" \
    -H "ClawMux-Session: ${CLAWMUX_SESSION_ID}" \
    --data-raw "$payload" \
    --max-time 5 \
    >/dev/null 2>&1 || true

exit 0
