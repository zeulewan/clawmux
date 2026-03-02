# Roadmap

Detailed release history and upcoming work. Each version page includes checklists, implementation notes, and agent attribution.

## Current

- [v0.6.0 — ClawMux CLI & Multi-Provider](v0.6.0/index.md): Replace MCP server with CLI, multi-provider backend, decentralized hub.
  - [ClawMux CLI](v0.5.0/cli.md): Replace MCP server with a CLI tool for voice converse and inter-agent messaging. Fire-and-forget, wait-for-ack, and wait-for-response modes. Tmux injection for message delivery.

## Future

- [v0.7.0 — Agent Orchestration](v0.7.0.md): Sub-agent workers, group messaging, public API.

## History

- [v0.5.0 — Polish & Reliability](v0.5.0/index.md): Final MCP release. Hub stability, browser bug fixes, UX polish.
- [v0.4.0 — iOS App](v0.4.0.md)
- [v0.3.0 — Multi-Session](v0.3.0.md)
- [v0.2.0 — Voice Modes](v0.2.0.md)
- [v0.1.0 — MCP Rewrite](v0.1.0.md)
- [v0.0.1 — Initial Release](v0.0.1.md)

## Reference

- [CLI Messaging Design](../reference/cli-messaging.md): Full technical spec for the ClawMux CLI — commands, message format, acknowledgment flow, hub architecture changes.
- [Orchestration Reference](../reference/orchestration.md): Session model, spawn flow, worker CLAUDE.md template, message routing, resource limits.
