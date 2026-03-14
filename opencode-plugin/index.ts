/**
 * ClawMux bridge plugin for OpenCode.
 *
 * Translates OpenCode hook events into POST /api/hooks/tool-status calls on the
 * ClawMux hub — mirroring what hooks/tool-status.sh does for Claude Code agents.
 *
 * Also checks the inbox (.inbox.jsonl) after each tool call and delivers pending
 * messages directly via the OpenCode prompt_async API — the OpenCode equivalent
 * of Claude Code's stop-check-inbox.sh hook.
 *
 * Registered in the workspace opencode.json via:
 *   { "plugin": ["file:///path/to/opencode-plugin"] }
 *
 * Required env vars (set by ClawMux hub at spawn time):
 *   CLAWMUX_PORT        — hub HTTP port
 *   CLAWMUX_SESSION_ID  — session identifier sent in the ClawMux-Session header
 *   OPENCODE_PORT        — local OpenCode HTTP server port (for inbox delivery)
 */

import type { Plugin } from "@opencode-ai/plugin"
import { readFileSync, writeFileSync, existsSync } from "fs"
import { join } from "path"

const TIMEOUT_MS = 5_000

interface InboxMessage {
  id?: string
  from?: string
  type?: string
  content?: string
  group_name?: string
  parent_id?: string
  ts?: number
}

interface OpenCodeInfo {
  port: number
  session_id: string
}

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

/**
 * Format inbox messages into the same text format the hub uses for tmux injection.
 */
function formatInboxMessages(messages: InboxMessage[]): string {
  const lines: string[] = []
  for (const msg of messages) {
    const msgType = msg.type ?? "system"
    const sender = msg.from ?? "unknown"
    const content = msg.content ?? ""
    const msgId = msg.id ?? ""
    if (msgType === "agent") {
      lines.push(`[MSG id:${msgId} from:${sender}] ${content}`)
    } else if (["voice", "text", "file_upload"].includes(msgType)) {
      lines.push(`[VOICE id:${msgId} from:${sender}] ${content}`)
    } else if (msgType === "group") {
      const groupName = msg.group_name ?? "group"
      lines.push(`[GROUP:${groupName} id:${msgId} from:${sender}] ${content}`)
    } else if (msgType === "ack") {
      lines.push(`[ACK from:${sender} on:${msg.parent_id ?? ""}]`)
    } else {
      lines.push(`[SYSTEM] ${content}`)
    }
  }
  return lines.join("\n")
}

/**
 * Read and clear .inbox.jsonl, returning parsed messages.
 */
function readAndClearInbox(workDir: string): InboxMessage[] {
  const inboxPath = join(workDir, ".inbox.jsonl")
  if (!existsSync(inboxPath)) return []
  let raw: string
  try {
    raw = readFileSync(inboxPath, "utf-8")
  } catch {
    return []
  }
  if (!raw.trim()) return []
  const messages: InboxMessage[] = []
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue
    try {
      messages.push(JSON.parse(line))
    } catch {
      // Skip malformed lines
    }
  }
  if (messages.length > 0) {
    try {
      writeFileSync(inboxPath, "")
    } catch {
      // Best effort clear
    }
  }
  return messages
}

/**
 * Load OpenCode session info from .clawmux-opencode.json (written by hub at spawn).
 * Falls back to OPENCODE_PORT env var + discovery if file is missing.
 */
function loadOpenCodeInfo(workDir: string): OpenCodeInfo | null {
  const infoPath = join(workDir, ".clawmux-opencode.json")
  if (existsSync(infoPath)) {
    try {
      const data = JSON.parse(readFileSync(infoPath, "utf-8"))
      if (data.port && data.session_id) return data as OpenCodeInfo
    } catch {
      // Fall through
    }
  }
  return null
}

export default (async ({ directory }) => {
  const port = process.env.CLAWMUX_PORT
  const sessionId = process.env.CLAWMUX_SESSION_ID

  // Not running inside a ClawMux session — register no hooks.
  if (!port || !sessionId) return {}

  const cwd = directory ?? process.cwd()

  // Cache OpenCode connection info (lazily loaded on first inbox check)
  let ocInfo: OpenCodeInfo | null = null

  async function checkAndDeliverInbox(): Promise<void> {
    const messages = readAndClearInbox(cwd)
    if (messages.length === 0) return

    // Lazy-load OpenCode connection info
    if (!ocInfo) {
      ocInfo = loadOpenCodeInfo(cwd)
      if (!ocInfo) return // Can't deliver without connection info
    }

    const text = formatInboxMessages(messages)
    try {
      await fetch(
        `http://localhost:${ocInfo.port}/session/${ocInfo.session_id}/prompt_async`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ parts: [{ type: "text", text }] }),
          signal: AbortSignal.timeout(TIMEOUT_MS),
        },
      )
    } catch {
      // Delivery failed — messages are already cleared from inbox.
      // The hub will re-send if needed via its own delivery path.
    }
  }

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

    // tool.execute.after — tool call completed → PostToolUse + inbox check
    "tool.execute.after": async (input, _output) => {
      await postToHub(port, sessionId, {
        hook_event_name: "PostToolUse",
        tool_name: input.tool,
        tool_input: input.args ?? {},
        cwd,
      })
      // Check inbox and deliver pending messages between tool calls
      await checkAndDeliverInbox()
    },

    // Catch session.idle via the generic event hook → Stop + final inbox check
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await postToHub(port, sessionId, {
          hook_event_name: "Stop",
          tool_name: "",
          tool_input: {},
          cwd,
        })
        await checkAndDeliverInbox()
      }
    },
  }
}) satisfies Plugin
