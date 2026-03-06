# Roadmap

Detailed release history and upcoming work. Each version page includes checklists, implementation notes, and agent attribution.

## Current

- [v0.8.0 — Direct API & Multi-Provider](v0.8.0.md): Direct Anthropic API migration, pluggable backends, streaming TTS.

## History

- [v0.7.0 — Architecture Refactor & Mobile Polish](v0.7.0/index.md): MCP removal, state machine, code extraction, mobile UX overhaul, deployment settings, activity logging.
- [v0.6.0 — Hook-Based Agent Communication](v0.6.0.md): Replaced tmux-injection messaging with Claude Code hooks for reliable, event-driven delivery. Unified `send`/`wait` commands, message threading, inbox-based architecture.
- [v0.5.0 — Polish & Reliability](v0.5.0/index.md): Inter-agent messaging, hub stability, browser bug fixes, UX polish. ClawMux CLI.
  - [ClawMux CLI](v0.5.0/cli.md): CLI tool for voice converse and inter-agent messaging.
- [v0.4.0 — iOS App](v0.4.0.md)
- [v0.3.0 — Multi-Session](v0.3.0.md)
- [v0.2.0 — Voice Modes](v0.2.0.md)
- [v0.1.0 — MCP Rewrite](v0.1.0.md)
- [v0.0.1 — Initial Release](v0.0.1.md)

## Vision

- [Vision Roadmap](vision.md): Long-term phases for federation, trust, and next-gen version control.

## Research

- [A2A Protocol Feasibility Study](a2a-feasibility.md): Assessment of integrating the Agent2Agent protocol for hub federation and external agent interop.

## Reference

- [Project Folders Spec](v0.6.0-projects.md): Multi-project architecture (shipped in v0.5.x).
- [CLI Messaging Design](../reference/cli-messaging.md): Full technical spec for the ClawMux CLI.
- [Orchestration Reference](../reference/orchestration.md): Session model, spawn flow, worker template, message routing, resource limits.
