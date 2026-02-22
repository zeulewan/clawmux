# Inter-Agent Communication

## Problem

Agents currently have no way to communicate with each other. Each session is completely isolated — the only interaction channel is between an agent and the human via voice. Use cases like "tell Echo to summarize this" or agents collaborating on a task behind the scenes are impossible.

Typing directly into another agent's tmux session doesn't work because the agent is typically blocked in a `converse()` call waiting for voice input. Text sent to the shell prompt sits there unprocessed until the current turn ends, and even then it's treated as a shell command, not Claude input.

## New MCP Tools

### `list_agents`

Returns currently active agents with their names and status (ready, active, listening, idle). Agents can call this anytime to discover who's online, since sessions can be spawned or terminated mid-conversation.

```python
@mcp.tool
async def list_agents() -> str:
    """List all active agents and their current status."""
```

Example response:
```
Agents online:
- Sky: Working (Reading files...)
- Adam: Listening
- Alloy: Idle (5 min)
- Echo: Working (Running tests...)
```

### `send_message(target, message)`

Sends a text message to another agent by voice name. The hub stores it in the target agent's inbox (in-memory, not on disk).

```python
@mcp.tool
async def send_message(target: str, message: str) -> str:
    """Send a text message to another agent.

    Args:
        target: Agent name (e.g., "Adam", "Sky-A")
        message: The message text
    """
```

### `check_inbox`

Returns any pending messages immediately (non-blocking). Agents can call this between converse cycles to check for inter-agent messages.

Shared with the message queuing system — returns both user-queued messages and inter-agent messages.

## Message Delivery via Converse

When an agent calls `converse(wait_for_response=true)`, the hub checks the agent's inbox before/after capturing voice. Pending messages are bundled into the converse result alongside the user's speech:

```
"User said: How's the refactor going? | Message from Adam: I finished the API docs, they're in docs/api.md"
```

If the agent is blocked waiting for voice and a message arrives, the hub can optionally interrupt the wait and return the message immediately, so agents are always reachable.

This piggyback approach means agents don't need to explicitly poll — messages arrive naturally with each converse cycle.

## Agent Autonomy

- The receiving agent decides whether to speak the message to the user or handle it silently.
- Agents can reply back to the sender via `send_message`, enabling back-and-forth without human involvement.
- The human can disconnect and agents can continue communicating as long as the hub is running — voice I/O is only needed for human interaction, not inter-agent messaging.

## Open Questions

- Should there be a message priority system (urgent messages interrupt converse, normal messages wait)?
- Should the hub provide a shared scratchpad / key-value store for passing structured data between agents?
- How should agents handle message ordering and conversation threading across multiple agents?
