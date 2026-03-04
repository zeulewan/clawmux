# ClawMux CLI

A command-line tool that replaces the MCP server as the agent's interface to the hub. Any agent runtime that can run bash — Claude Code, OpenClaw, Codex — uses `clawmux` to speak to users and communicate with other agents.

## Voice Converse

The `clawmux converse` command handles all voice interaction. The agent calls it with a message, the hub plays it via TTS, optionally listens for a spoken response via STT, and returns the transcription on stdout.

```
clawmux converse "What should I work on?"        # speak + listen
clawmux converse "Got it." --no-listen            # speak only
clawmux converse "Goodbye!" --goodbye             # end session
```

This replaces the current MCP `converse()` tool. The CLI connects to the hub over WebSocket, sends the request, waits for the result, prints it, and exits. No persistent connection to maintain.

## Inter-Agent Messaging

Agents send messages to each other with `clawmux send`. The hub injects messages into the recipient's tmux pane via `tmux send-keys`, so they appear as user input when the agent's current turn ends.

### Sending Modes

**Fire and forget** — send and move on immediately. Use for notifications and FYI messages.

```
clawmux send --to alloy "I pushed a fix to auth."
```

**Wait for acknowledgment** — block until the recipient confirms they read the message. Useful when you need to know the message was received before continuing.

```
clawmux send --to alloy --wait-ack "Check the auth module when you can."
```

**Wait for response** — block until the recipient sends a reply back. Use when asking a question that needs an answer.

```
clawmux send --to alloy --wait-response "What port is the dev server on?"
```

All modes print the message ID to stdout. Wait modes also print the acknowledgment or reply text when it arrives, with configurable timeouts (30s for ack, 120s for response by default).

### Message Format

Injected messages have a structured prefix so the agent knows who sent it, where it's going, and what's expected:

```
[MSG id:msg-a1b2c3 from:alloy to:sky expect-response] What port is the dev server on?
```

The `to:` field is there for debugging — if a message lands in the wrong pane, the recipient can see it wasn't for them. The `expect-response` flag tells the recipient that the sender is waiting.

### Receiving Messages

When an agent reads an injected message, it immediately acknowledges receipt:

```
clawmux ack msg-a1b2c3
```

This unblocks any sender waiting with `--wait-ack`. If the message has `expect-response`, the agent processes the request and replies:

```
clawmux reply msg-a1b2c3 "Port 8080."
```

This unblocks the sender waiting with `--wait-response` and delivers the reply text.

## Message Lifecycle

The hub tracks every message through four states:

**Pending** — created and injected into the recipient's tmux pane. Waiting for acknowledgment.

**Acknowledged** — recipient called `clawmux ack`. Message was read.

**Responded** — recipient called `clawmux reply`. Sender received the reply.

**Failed** — re-injected 3 times over 3 minutes with no acknowledgment. Marked failed, reported on sender's next interaction.

The hub stores all messages in memory with full history: ID, sender, recipient, content, flags, state, timestamps, and retry count. This is the single source of truth for debugging.

## Status

```
clawmux status
```

Shows whether the browser is connected, which agent sessions are active, and any pending or failed messages for the calling agent.

## Session Setup

When the hub spawns a new agent session, it writes `/clawmux` into the tmux pane. This triggers a skill that teaches the agent all the CLI commands, the message format, and how to handle injected messages. The skill describes when to use each sending mode, how to ack immediately on receipt, and the expected response patterns.

The `CLAWMUX_SESSION_ID` environment variable identifies the agent session, same as the current MCP server.

## Hub Architecture

The hub gains a message broker — an in-memory store tracking all messages by ID. A new WebSocket path `/cli/{session_id}` handles short-lived CLI connections: connect, send one request, receive one response, disconnect. The hub uses `tmux send-keys` to inject formatted messages into target panes.

Message state is also exposed to the browser via the existing WebSocket, enabling a real-time message log in the UI for debugging inter-agent communication.

## Migration

The MCP server stays operational during transition. Sessions switch one at a time from MCP `converse()` to `clawmux converse`. Once all sessions migrate, the MCP server is retired.

## Checklist

- [ ] `clawmux converse` — speak, listen, goodbye modes
- [ ] `clawmux send` — fire-and-forget mode
- [ ] `clawmux send --wait-ack` — blocking until acknowledgment
- [ ] `clawmux send --wait-response` — blocking until reply
- [ ] `clawmux ack` — acknowledge message receipt
- [ ] `clawmux reply` — respond to a message
- [ ] `clawmux status` — hub and message state
- [ ] Hub message broker — in-memory message store with lifecycle tracking
- [ ] Hub `/cli/{session_id}` WebSocket endpoint
- [ ] Tmux message injection via `send-keys`
- [ ] Message retry logic (3 attempts, 60s intervals)
- [ ] `/clawmux` skill file for agent onboarding
- [ ] Browser message log UI
- [ ] MCP server retirement after full migration
