# v0.6.0 - ClawMux CLI & Agent Orchestration

Replace the MCP server with the ClawMux CLI. Add multi-backend support, sub-agent workers, and infrastructure improvements.

## ClawMux CLI

The MCP server is retired in favor of `clawmux`, a CLI tool for voice converse and inter-agent messaging. Any agent runtime that can run bash — Claude Code, OpenClaw, Codex — uses the same interface. The browser UI gets a right-click menu on sessions to launch with either MCP (legacy) or CLI during the migration period.

Full spec: [CLI Messaging Design](../../reference/cli-messaging.md)

## Dual Backend

The hub gets a pluggable backend interface so it can run sessions through either Claude Code (tmux) or OpenClaw (Gateway WebSocket). Both implement the same spawn/terminate/message interface. The frontend doesn't know which backend is underneath.

## Sub-Agent Workers

Each agent can spawn lightweight workers that inherit its voice and appear nested in the sidebar. Single-level hierarchy — workers can't spawn their own workers. Leaders get tools to spawn, list, kill, and message workers. Max 4 workers per leader, auto-terminate after 30 minutes idle.

## Status Visibility

Agents push status updates between converse calls so the browser shows "Working" or "Reading files..." instead of just "Ready." Idle timeout after 60 seconds of silence.

## Deferred from v0.5.0

- [ ] Hold-aware timeout — exempt sessions with pending converse calls from inactivity timeout.
- [ ] Streaming TTS — stream audio chunks to reduce time-to-first-audio.
- [ ] Configurable STT/TTS URLs — run Whisper and Kokoro on a different machine.
- [ ] One-command setup — single install script.
- [ ] Standalone STT/TTS installs — Whisper and Kokoro from upstream with systemd files.
- [ ] Whisper model selection — choose model size from settings.
- [ ] Public API — token auth, versioned endpoints, agent management.
- [ ] Code block rendering — render code blocks in agent responses.
- [ ] Right-click session menu — launch with MCP or CLI.
