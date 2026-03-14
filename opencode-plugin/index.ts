/**
 * ClawMux bridge plugin for OpenCode.
 *
 * Translates OpenCode hook events into POST /api/hooks/tool-status calls on the
 * ClawMux hub — mirroring what hooks/tool-status.sh does for Claude Code agents.
 *
 * Registered in the workspace opencode.json via:
 *   { "plugin": ["file:///path/to/opencode-plugin"] }
 *
 * Required env vars (set by ClawMux hub at spawn time):
 *   CLAWMUX_PORT        — hub HTTP port
 *   CLAWMUX_SESSION_ID  — session identifier sent in the ClawMux-Session header
 */

import type { Plugin } from "@opencode-ai/plugin"

const TIMEOUT_MS = 5_000

async function postToHub(
  port: string,
  sessionId: string,
  payload: Record<string, unknown>,
): Promise<void> {
  try {
    await fetch(`http://localhost:${port}/api/hooks/tool-status`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "ClawMux-Session": sessionId,
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    })
  } catch {
    // Silently ignore — hub may not be reachable, and we must never block the agent.
  }
}

export default (async ({ directory }) => {
  const port = process.env.CLAWMUX_PORT
  const sessionId = process.env.CLAWMUX_SESSION_ID

  // Not running inside a ClawMux session — register no hooks.
  if (!port || !sessionId) return {}

  const cwd = directory ?? process.cwd()

  return {
    // tool.execute.before — agent is about to call a tool → PreToolUse
    "tool.execute.before": async (input, output) => {
      await postToHub(port, sessionId, {
        hook_event_name: "PreToolUse",
        tool_name: input.tool,
        tool_input: output.args ?? {},
        cwd,
      })
    },

    // tool.execute.after — tool call completed → PostToolUse
    "tool.execute.after": async (input, _output) => {
      await postToHub(port, sessionId, {
        hook_event_name: "PostToolUse",
        tool_name: input.tool,
        tool_input: input.args ?? {},
        cwd,
      })
    },

    // Catch session.idle via the generic event hook → Stop
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await postToHub(port, sessionId, {
          hook_event_name: "Stop",
          tool_name: "",
          tool_input: {},
          cwd,
        })
      }
    },
  }
}) satisfies Plugin
