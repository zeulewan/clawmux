# CLI Messaging Design

Inter-agent communication and voice converse via a lightweight CLI tool called `clawmux`. Replaces the MCP server with simple shell commands that any agent runtime can call — Claude Code, OpenClaw, Codex, or anything else that runs bash.

## Why CLI Over MCP

The current MCP server (`hub_mcp_server.py`) requires each agent to maintain a persistent WebSocket connection to the hub. This means reconnection logic, token overhead from MCP protocol framing, and a hard dependency on runtimes that support MCP. A CLI tool sidesteps all of this. The CLI connects to the hub, does one thing, prints the result to stdout, and exits. No state to manage, no reconnection loops, no protocol overhead.

Every agent runtime can run bash commands. That's the universal interface. By building on it, ClawMux works with any backend without modification.

## Commands

### clawmux converse

Speaks a message to the user via TTS and optionally listens for their spoken response via STT. This replaces the MCP `converse()` tool.

```
clawmux converse "What should I work on next?"
clawmux converse "Done with that." --no-listen
clawmux converse "Goodbye!" --goodbye
```

The CLI connects to the hub, sends the converse request, waits for the TTS/STT round-trip, prints the user's transcribed speech to stdout, and exits. The agent reads stdout like any other command output. If `--no-listen` is set, it speaks and exits without waiting for a response.

### clawmux send

Sends a message to another agent session. Three modes control how the sender behaves after sending.

**Fire and forget** (default). Send the message and exit immediately. The agent moves on without waiting.

```
clawmux send --to alloy "FYI, I pushed a fix to the auth module."
```

**Wait for acknowledgment**. Block until the recipient agent confirms it read the message, or until timeout.

```
clawmux send --to alloy --wait-ack "Can you check the auth module when you get a chance?"
```

**Wait for response**. Block until the recipient agent sends a reply back, or until timeout. Use this when asking a question that needs an answer.

```
clawmux send --to alloy --wait-response "What port is the dev server running on?"
```

The `--wait-response` flag also sets an `expect_response` flag on the injected message, telling the recipient that the sender is waiting for a reply. The recipient sees this and knows to respond promptly.

All modes print the message ID to stdout. Wait modes also print the acknowledgment or response text when it arrives.

### clawmux ack

Acknowledges receipt of a message. The recipient agent calls this as soon as it reads an injected message, before doing any work on it.

```
clawmux ack msg-a1b2c3
```

This tells the hub the message was received. If the sender used `--wait-ack`, they get unblocked at this point.

### clawmux reply

Sends a response to a specific message. Used when the sender set `--wait-response`.

```
clawmux reply msg-a1b2c3 "It's running on port 8080."
```

The hub routes this back to the original sender, unblocking their `--wait-response` call.

### clawmux start

Starts the ClawMux hub. Launches the hub process, binds to the configured port, and begins accepting connections.

```
clawmux start
clawmux start --port 3460
```

### clawmux stop

Stops the ClawMux hub gracefully. Active agent sessions are preserved in tmux — they just lose hub connectivity until the hub restarts.

```
clawmux stop
```

### clawmux status

Shows hub state, active sessions, and any pending or failed messages. With no arguments, shows the full overview. With an agent name, shows detailed status for that agent.

```
clawmux status
clawmux status sky
clawmux status --all
```

**Hub overview** (no arguments):

- Hub uptime and port
- Browser connection status
- List of active sessions with current state (idle, thinking, speaking, listening)
- Pending/failed message counts

**Agent detail** (`clawmux status sky`):

- Current state: idle, thinking, speaking, listening, or in a converse call
- What the agent is working on (if it has pushed a status update)
- Pending inbound messages
- Recent message history (last 10 sent/received)
- Session uptime

## Message Injection

When Agent A sends a message to Agent B, the hub injects it into B's tmux pane using `tmux send-keys`. The message format includes sender, recipient, message ID, and flags:

```
[MSG id:msg-a1b2c3 from:alloy to:sky expect-response] Can you check the auth module?
```

The agent sees this as user input when its current turn ends. Claude Code processes it naturally — it reads the prefix to understand who sent it and what's expected, then acts on the content. No special parsing logic needed in the agent; CLAUDE.md instructions tell it how to handle messages with the `[MSG ...]` prefix.

The `to:sky` field is there for debugging. If a message accidentally goes to the wrong pane, the recipient can see it wasn't meant for them.

## Message Lifecycle

Each message goes through states tracked by the hub:

**Pending** — message created, injected into recipient's tmux pane, waiting for acknowledgment.

**Acknowledged** — recipient called `clawmux ack`. The message was read. If the sender used `--wait-ack`, they're unblocked.

**Responded** — recipient called `clawmux reply`. If the sender used `--wait-response`, they receive the reply text and are unblocked.

**Failed** — message was re-injected 3 times over 3 minutes with no acknowledgment. The hub marks it failed and reports the failure on the sender's next `clawmux status` or `clawmux converse` call.

The hub stores all messages in memory with their full history: ID, sender, recipient, content, flags, state, timestamps, and retry count. This is the single source of truth for debugging message delivery.

## Session Identity

Each agent session has an ID derived from its voice name (`af_sky`, `af_alloy`, etc.). The CLI reads `VOICE_HUB_SESSION_ID` from the environment, same as the current MCP server. The `--to` flag accepts human-friendly names like `sky`, `alloy`, `echo` — the hub resolves these to session IDs.

## Hub Changes

The hub needs a message broker: an in-memory dict tracking all messages by ID with their lifecycle state. A new WebSocket path `/cli/{session_id}` handles short-lived CLI connections — connect, send one request, receive one response, disconnect. And `tmux send-keys` calls to inject formatted messages into target panes.

The hub can also expose message state via the browser WebSocket, showing a message log or notification when agents are communicating.

## Migration

The MCP server continues working alongside the CLI during transition. Session CLAUDE.md files switch from MCP `converse()` to `clawmux converse`. Once all sessions migrate, the MCP server is retired. The CLI binary lives in the repo and gets installed into agent session paths.

## Open Questions

How should multiple messages queue when an agent is mid-turn? Tmux send-keys would inject them sequentially, so they appear as separate user inputs. The hub could batch messages with a short delay, or the agent could handle them one at a time.

What timeout values should `--wait-ack` and `--wait-response` use? Probably configurable with reasonable defaults — 30 seconds for ack, 120 seconds for response.

Should the hub expose a message log in the browser UI? This would let the user see all inter-agent communication in real time, which is valuable for debugging and trust.
