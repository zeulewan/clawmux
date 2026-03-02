# Roadmap

Detailed release history and upcoming work. Each version page includes checklists, implementation notes, and agent attribution.

## Current

- [v0.5.0 — Polish & Reliability](../roadmap/v0.5.0/index.md): Hub stability, browser bug fixes, UX polish, iOS improvements, ClawMux CLI.
  - [ClawMux CLI](../roadmap/v0.5.0/cli.md): Replace MCP server with a CLI tool for voice converse and inter-agent messaging. Fire-and-forget, wait-for-ack, and wait-for-response modes. Tmux injection for message delivery.

## Future

- [v0.6.0 — Agent Orchestration](../roadmap/v0.6.0/index.md): Dual backend (OpenClaw + tmux), sub-agent workers, status visibility, infrastructure setup.

## History

- [v0.4.0 — iOS App](../roadmap/v0.4.0.md)
- [v0.3.0 — Multi-Session](../roadmap/v0.3.0.md)
- [v0.2.0 — Voice Modes](../roadmap/v0.2.0.md)
- [v0.1.0 — MCP Rewrite](../roadmap/v0.1.0.md)
- [v0.0.1 — Initial Release](../roadmap/v0.0.1.md)

## Reference

- [CLI Messaging Design](reference/cli-messaging.md): Full technical spec for the ClawMux CLI — commands, message format, acknowledgment flow, hub architecture changes.
- [Orchestration Reference](reference/orchestration.md): Session model, spawn flow, worker CLAUDE.md template, message routing, resource limits.
