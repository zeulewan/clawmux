# Roadmap

ClawMux development roadmap. Each release builds toward reliable, scalable multi-agent voice collaboration.

## Current Release

### v0.5.1 — Bug Fixes & UI Improvements :white_check_mark:

- Bug fixes and stability improvements
- UI enhancements for the browser hub
- Hooks-based status system for agent monitoring

## Next Up

### [v0.6.0 — Hook-Based Agent Communication](v0.6.0.md)

Replace tmux-injection messaging with Claude Code hooks for reliable, event-driven agent communication. Near-real-time message delivery, no message loss, no session corruption.

## Future

### v0.7.0 — Direct API Migration

Migrate from Claude Code CLI to direct Anthropic API access. Adopt OpenClaw-style architecture with streaming, session persistence, and native tool definitions. Eliminates the Claude Code process layer entirely.

### v0.8.0 — A2A Protocol Support

[Agent-to-Agent protocol](../briefs/a2a.md) integration for cross-platform agent communication. Let ClawMux agents talk to external agent systems.

### v0.9.0 — Multi-Device Deployment

[Deployment modes](../briefs/deployment-modes.md) for running ClawMux across different devices, networks, and configurations.
