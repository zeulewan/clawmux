# v0.6.0 - Agent Orchestration

Multi-backend support, sub-agent workers, and infrastructure improvements.

## Dual Backend

The hub gets a pluggable backend interface so it can run sessions through either Claude Code (tmux) or OpenClaw (Gateway WebSocket). Both implement the same spawn/terminate/message interface. The frontend doesn't know which backend is underneath.

## Sub-Agent Workers

Each agent can spawn lightweight workers that inherit its voice and appear nested in the sidebar. Single-level hierarchy — workers can't spawn their own workers. Leaders get tools to spawn, list, kill, and message workers. Max 4 workers per leader, auto-terminate after 30 minutes idle.

## Status Visibility

Agents push status updates between converse calls so the browser shows "Working" or "Reading files..." instead of just "Ready." Idle timeout after 60 seconds of silence.

## Setup & Infrastructure

- [ ] One-command setup — single script that installs all dependencies.
- [ ] Standalone STT/TTS installs — Whisper and Kokoro from upstream with systemd service files.
- [ ] Whisper model selection — choose model size from settings.
- [ ] Public API — token auth, versioned endpoints, agent management for external clients.
