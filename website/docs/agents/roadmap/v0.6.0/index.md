# v0.6.0 - ClawMux CLI & Multi-Provider

Replace the MCP server with the ClawMux CLI. Add multi-provider support and decentralize the hub.

## ClawMux CLI

The MCP server is retired in favor of `clawmux`, a CLI tool for voice converse and inter-agent messaging. Any agent runtime that can run bash — Claude Code, OpenClaw, Codex — uses the same interface. The browser UI gets a right-click menu on sessions to launch with either MCP (legacy) or CLI during the migration period.

Full spec: [CLI Messaging Design](../../reference/cli-messaging.md)

- [ ] `clawmux converse` — speak and listen, replacing the MCP converse tool.
- [ ] `clawmux send` — inter-agent messaging with fire-and-forget, wait-for-ack, and wait-for-response modes.
- [ ] `clawmux ack` / `clawmux reply` — acknowledge and respond to injected messages.
- [ ] `clawmux status` — hub overview and per-agent detail (idle, thinking, speaking, working on X).
- [ ] `clawmux start` / `clawmux stop` — hub lifecycle management.
- [ ] Hub message broker — in-memory message tracking with lifecycle states (pending → ack → responded → failed).
- [ ] Tmux injection — deliver messages via `tmux send-keys` with structured `[MSG ...]` prefix.
- [ ] Right-click session menu — launch with MCP or CLI.

## Decentralized Hub

- [ ] Configurable STT/TTS URLs — run agents on a local machine, use Kokoro and Whisper from a remote workstation.

## Status Visibility

Agents push status updates between converse calls so the browser shows "Working" or "Reading files..." instead of just "Ready." Idle timeout after 60 seconds of silence.

## Multi-Provider Backend

The hub gets a pluggable backend interface so it can run sessions through Claude Code (tmux), OpenClaw (Gateway WebSocket), or OpenAI-compatible agents. All backends implement the same spawn/terminate/message interface. The frontend doesn't know which backend is underneath.

- [ ] Backend interface — abstract spawn, terminate, send, and status behind a common interface.
- [ ] Claude Code backend — current tmux-based session management, extracted into the interface.
- [ ] OpenClaw backend — spawn and manage OpenClaw sessions via Gateway WebSocket.
- [ ] OpenAI backend — support OpenAI-compatible agents.

## Deferred from v0.5.0

- [ ] Hold-aware timeout — exempt sessions with pending converse calls from inactivity timeout.
- [ ] Streaming TTS — stream audio chunks to reduce time-to-first-audio.
- [ ] One-command setup — single install script.
- [ ] Code block rendering — render code blocks in agent responses.
