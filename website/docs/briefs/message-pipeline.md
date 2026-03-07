# Message Pipeline Brief

*Brief #4 — Created: 2026-03-07*

How ClawMux will deliver messages reliably between the hub, agents, and the browser.

## The Problem

The current message pipeline has several interconnected bugs:

1. **Messages disappear and reappear** — the browser does a full re-render of all messages every 5 seconds (history sync). This clears the DOM and rebuilds it, causing a visual flash and sometimes losing messages temporarily.

2. **Entry animation replays** — the history sync re-render triggers the CSS intro animation on all messages, not just new ones.

3. **Race condition between hooks and wait** — when a user sends a message right as an agent finishes processing, the PreToolUse hook consumes the inbox before `clawmux wait` can read it. The message is delivered via hook context, but Claude is blocked on `wait` and cannot act on it until a second message arrives.

4. **Half-dead WebSocket connections** — `send_to_browser` silently drops messages when a WebSocket connection is broken in one direction. The message is lost and only appears on the next history sync.

These are all symptoms of two root causes:

- **The browser treats the server as the source of truth** and periodically re-fetches everything, instead of maintaining its own local state and only appending new messages.
- **The agent inbox has two competing consumers** (hooks and `clawmux wait`) with no coordination, leading to race conditions.

## How Messaging Apps Do It

Real messaging apps (Signal, Slack, Discord, Mattermost, Rocket.Chat) all follow the same pattern:

- **Push, don't poll.** New messages arrive via WebSocket push. There is no periodic sync.
- **Append, don't replace.** New messages are appended to the DOM. The chat is never cleared and rebuilt.
- **Client-side store.** The browser keeps its own array of messages in memory. This is the source of truth for what is on screen.
- **Cursor-based reconnect.** On disconnect/reconnect, the client sends its last known message ID. The server returns only what was missed. The client appends the gap.
- **Full fetch only on first load.** History is fetched once on page load, then WebSocket takes over.

## The New Architecture

### Phase 1: Browser Viewport (frontend)

Stop polling. Stop re-rendering. Adopt the standard messaging app pattern.

**Changes:**

1. **Append-only DOM** — when a message arrives via WebSocket, create one new element and append it. Never clear the chat container.
2. **Remove the 5-second history sync poll** — delete the `setInterval` that fetches `/api/history` every 5 seconds. WebSocket push is the only way messages appear after initial load.
3. **Client-side message store** — maintain a JavaScript array of all messages in memory. Each message has a unique ID. This array is the source of truth for the viewport.
4. **Cursor-based reconnect** — when the WebSocket reconnects after a disconnect, send the last known message ID to the server. Server returns only messages after that ID. Client appends the gap.
5. **Full history on page load** — on first load or hard reload, fetch all history from the server, populate the client store, render once.
6. **Queue failed sends** — if `send_to_browser` fails on a dead connection, queue the message. Replay on reconnect.

### Phase 2: Agent Inbox (backend)

Fix the competing-consumer race condition between hooks and `clawmux wait`.

**Design principles:**

- **Single consumer** — only one thing should read and clear the inbox, eliminating contention.
- **RAM-based queue** — move the live message queue from a JSON file into an in-memory Python list on the session object. Faster, no file locking needed, protected by the single-threaded asyncio event loop.
- **JSON file as backup** — write messages to disk asynchronously for crash recovery. Not used for live delivery.
- **Hooks deliver, wait blocks** — hooks peek at the queue and inject messages into Claude's context via `additionalContext`. `clawmux wait` blocks until a new message is pushed. If hooks already delivered messages since the last `wait`, `wait` returns immediately so Claude can process them.

**Detailed design TBD** — Phase 2 will be specced after Phase 1 is implemented and validated.

## What Does Not Change

- The hub is still FastAPI on port 3460
- Agents still use `clawmux send` and `clawmux wait`
- The stop hook still fires on agent completion
- History is still persisted to `~/.clawmux/sessions/<agent_id>/history.json`
- The browser UI is still vanilla JS/HTML/CSS — no frameworks

## Implementation Plan

Phase 1 and Phase 2 are sequential. Phase 1 (browser) ships first, Phase 2 (backend) follows.

See the implementation spec (separate document) for file-level changes, code diffs, and rollback plan.
