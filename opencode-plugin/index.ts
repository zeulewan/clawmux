/**
 * ClawMux bridge plugin for OpenCode.
 *
 * Translates OpenCode hook events into POST /api/hooks/tool-status calls on the
 * ClawMux hub — mirroring what hooks/tool-status.sh does for Claude Code agents.
 *
 * Loaded via .opencode/plugins/ in the agent workspace (symlinked or copied by
 * OpenCodeBackend at spawn time). Also works from ~/.config/opencode/plugins/ for
 * global use.
 *
 * Required env vars (set by ClawMux hub at spawn time):
 *   CLAWMUX_PORT        — hub HTTP port
 *   CLAWMUX_SESSION_ID  — session identifier sent in the ClawMux-Session header
 */

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

export default function clawmuxPlugin(ctx: any) {
  const port = process.env.CLAWMUX_PORT
  const sessionId = process.env.CLAWMUX_SESSION_ID

  // Not running inside a ClawMux session — register no hooks.
  if (!port || !sessionId) return {}

  // Prefer the plugin context directory; fall back to process cwd.
  const cwd: string = ctx?.directory ?? ctx?.project?.directory ?? process.cwd()

  return {
    /**
     * tool.execute.before — agent is about to call a tool.
     * Maps to PreToolUse on the hub.
     *
     * OpenCode passes the tool invocation as the first argument. Field names
     * vary across versions so we check both `name`/`tool` and `input`/`args`.
     */
    "tool.execute.before": async (event: any) => {
      await postToHub(port, sessionId, {
        hook_event_name: "PreToolUse",
        tool_name: event?.name ?? event?.tool ?? "",
        tool_input: event?.input ?? event?.args ?? {},
        cwd,
      })
    },

    /**
     * tool.execute.after — tool call completed (success or failure).
     * Maps to PostToolUse or PostToolUseFailure on the hub.
     *
     * The second argument carries the result; presence of `result.error`
     * determines which event name we send.
     */
    "tool.execute.after": async (event: any, result: any) => {
      const isError = result?.error != null
      await postToHub(port, sessionId, {
        hook_event_name: isError ? "PostToolUseFailure" : "PostToolUse",
        tool_name: event?.name ?? event?.tool ?? "",
        tool_input: event?.input ?? event?.args ?? {},
        cwd,
      })
    },

    /**
     * stop — OpenCode fires this when the agent finishes its turn.
     * Maps to Stop on the hub (matching Claude Code's Stop hook).
     */
    "stop": async () => {
      await postToHub(port, sessionId, {
        hook_event_name: "Stop",
        tool_name: "",
        tool_input: {},
        cwd,
      })
    },

    /**
     * session.idle — alternative idle signal some OpenCode versions emit.
     * Also maps to Stop so the hub marks the session as idle.
     */
    "session.idle": async () => {
      await postToHub(port, sessionId, {
        hook_event_name: "Stop",
        tool_name: "",
        tool_input: {},
        cwd,
      })
    },
  }
}
