# For Agents

Reference for AI agents installing, maintaining, or extending ClawMux. If you're a human, see the [human guide](../humans/index.md).

## Entry Points

Start here depending on what you're working on:

| Role | Document | Description |
|------|----------|-------------|
| **iOS Dev** | [iOS Development](ios-dev.md) | Building the native iOS app. What to read, what to implement, what files to watch |
| **Web Dev** | [Web Development](web-dev.md) | Building browser features. What docs to keep updated, conventions, testing |

## Roadmap

- [Roadmap](roadmap/index.md) — release history, current work, and upcoming plans
- [Vision](roadmap/vision.md) — long-term phases for federation, trust, and VCS

## Vision

Long-term architecture for federation, trust, and next-gen version control:

| Document | Description |
|----------|-------------|
| [Agent Federation](federation.md) | Decentralized agent-to-agent communication via A2A protocol |
| [Trust & Reputation](trust.md) | Trust tiers, dynamic scoring, cryptographic verification |
| [Next-Gen Version Control](vcs.md) | CRDT-based real-time collaborative editing, checkpoint model |

## Reference

| Document | Description |
|----------|-------------|
| [Agent Reference](reference/agent-reference.md) | System requirements, installation, file map, core flows, config, debugging |
| [Hub Architecture](reference/hub.md) | How the hub works, components, session lifecycle, slash commands |
| [WebSocket Protocol](reference/protocol.md) | Complete message reference for browser and MCP clients |
| [UI Behavior](reference/ui-behavior.md) | Every state, button, toggle, and audio behavior in the browser UI |
| [Orchestration](reference/orchestration.md) | Session model, spawn flow, worker template, message routing |
| [CLI Messaging](reference/cli-messaging.md) | ClawMux CLI technical spec |
| [State Machine](reference/state-machine.md) | Agent state machine documentation |
| [Configuration](reference/configuration.md) | Environment variables and config options |
| [Project Folders](reference/project-folders.md) | Multi-project architecture spec |
| [A2A Feasibility](reference/a2a-feasibility.md) | Agent2Agent protocol feasibility study |
| [Architecture (Legacy)](reference/architecture.md) | Single-session mode architecture (pre-hub) |
