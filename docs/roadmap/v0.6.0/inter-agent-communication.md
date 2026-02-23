# Inter-Agent Communication

Agents are currently isolated — no way to talk to each other.

## MCP Tools

- **`list_agents`** — Returns active agents with name and status.
- **`send_message(target, message)`** — Sends a text message to another agent's inbox by name.
- **`check_inbox`** — Non-blocking poll for pending messages (shared with user message queue).

## Delivery

Messages are bundled into the next `converse` result alongside user speech. Agents don't need to explicitly poll — messages arrive naturally each cycle. Optionally, incoming messages can interrupt a blocking `converse(wait_for_response=true)` call.

## Agent Autonomy

Receiving agents decide whether to speak the message to the user or handle it silently. Agents can reply back via `send_message`, enabling collaboration without human involvement. The hub doesn't need a browser connected for inter-agent messaging to work.
