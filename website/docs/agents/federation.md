# Agent Federation

Each person runs their own ClawMux hub or OpenClaw gateway. Agents are discoverable via A2A protocol manifests. Remote users can request to communicate with your agents.

## A2A Protocol

A2A (formerly ACP — Agent Communication Protocol) is the Linux Foundation standard for agent-to-agent communication. Created by IBM Research in March 2025, merged with Google's A2A protocol in August 2025 under Linux Foundation LF AI & Data.

- REST-first — standard HTTP (GET, POST, PUT, DELETE)
- JSON messages with MIME-typed parts (text, audio, images, video)
- Agent Manifests for discovery — agents advertise capabilities without exposing internals
- Three communication modes: synchronous, async (fire-and-forget + poll), and streaming (SSE)
- Python and TypeScript SDKs available (`beeai-framework[acp]`)

## What A2A Handles vs What's Custom

**A2A (protocol):**

- Message exchange between agents
- Acknowledgment and task status tracking
- Agent discovery via manifests
- Streaming responses (SSE/WebSocket)
- Session and context management
- Multimodal payloads

**Custom (orchestration):**

- Spawning and killing agent processes
- Runtime lifecycle management
- STT/TTS voice pipeline
- Health monitoring and auto-restart
- Model selection and switching
- Web and mobile UI

## OpenClaw Integration

OpenClaw already has 40+ channel extensions (Slack, Discord, Telegram, WhatsApp, etc.), each wrapping a platform-specific API. A2A would be another extension — `extensions/a2a/` — exposing hub agents as A2A-compatible endpoints.

This means:

- Hub agents (Sky, Echo, etc.) appear as standard A2A agents
- Any A2A-compatible client can discover and talk to them
- OpenClaw's iOS app becomes just another A2A client
- Other people's agents can interact with yours through the same protocol

## Cold Messages

Even with zero reputation, anyone can send a short introductory message (a couple sentences). This goes directly to human review as a pending request — never fed into agent context. Zero risk since it's just text shown to the human.

This is how new trust relationships start. Without it, the network is closed and nobody new can ever join.

## Related

- [A2A Protocol](https://agentcommunicationprotocol.dev/introduction/welcome)
- [BeeAI Framework](https://framework.beeai.dev)
- [Original ACP paper](https://arxiv.org/abs/2602.15055) (Naveen Kumar Krishnan, Feb 2026)
