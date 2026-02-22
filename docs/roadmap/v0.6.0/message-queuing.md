# Message Queuing

Users currently can't send messages to an agent that's between converse cycles (working on a task). Voice input is only captured during a `converse(wait_for_response=true)` call, and typed messages are only processed when the agent is listening.

## User Messages While Agent Works

Allow the user to record or type messages at any time. If the agent is between converse cycles, the hub queues the message and delivers it on the next `converse(wait_for_response=true)` call.

**Implementation:**

- Add a `message_queue: list[str]` to the Session model
- Browser always allows typing/recording, even when status is "Working"
- Hub stores queued messages with timestamps
- On next `converse(wait_for_response=true)`, hub prepends queued messages to the response:
  ```
  "[Queued message from 2 minutes ago]: Can you also update the tests?\n\nUser said: How's it going?"
  ```

## Queue Indicator

Browser shows a badge or indicator when messages are queued:

- Small counter badge on the session tab (e.g., "Sky (2)")
- Status text: "2 messages queued"
- Messages shown in chat with a "queued" styling (dimmed, with clock icon)
- When delivered, messages update to normal styling

## `check_inbox` Tool

New MCP tool that lets agents poll for queued messages without blocking:

```python
@mcp.tool
async def check_inbox() -> str:
    """Check for pending messages from the user or other agents.

    Returns immediately with any queued messages, or empty string if none.
    Non-blocking — does not wait for new input.

    Returns:
        Queued messages, or "(no messages)" if inbox is empty.
    """
```

This lets agents check mid-task:

1. Agent starts a long refactoring task
2. User types "actually, skip the tests for now"
3. Agent calls `check_inbox()` between file edits
4. Gets the message and adjusts its approach

Agents aren't required to poll — messages also arrive automatically with the next `converse` call. But `check_inbox` enables more responsive agents that can adapt mid-task.
