# v0.7.0 — Direct API & Multi-Provider

Migrate from Claude Code CLI to direct Anthropic API access. Add pluggable backend support for multiple AI providers.

## Direct API Migration

Replace the Claude Code process layer with direct `@anthropic-ai/sdk` streaming. Adopt OpenClaw-style architecture:

- [ ] Direct `client.messages.stream()` calls instead of Claude Code CLI
- [ ] Session lane + global lane concurrency control for multi-agent coordination
- [ ] JSONL session files for conversation persistence and resume
- [ ] Block reply pipeline adapted for TTS segment delivery
- [ ] Native tool definitions (read, write, exec, send, converse) registered via API
- [ ] Context window management with auto-compaction

## Multi-Provider Backend

Pluggable backend interface so the hub can run sessions through different AI providers:

- [ ] Backend interface — abstract spawn, terminate, send, and status behind a common interface
- [ ] Claude Code backend — current tmux-based session management (legacy, for migration period)
- [ ] Anthropic API backend — direct streaming via SDK
- [ ] OpenClaw backend — spawn and manage sessions via Gateway WebSocket
- [ ] OpenAI-compatible backend — support OpenAI and compatible agents

## Decentralized Hub

- [ ] Configurable STT/TTS URLs — run agents on a local machine, use Kokoro and Whisper from a remote workstation
- [ ] Streaming TTS — stream audio chunks to reduce time-to-first-audio

## Other

- [ ] One-command setup — single install script
- [ ] Code block rendering — render code blocks in agent responses
- [ ] Hold-aware timeout — exempt sessions with pending calls from inactivity timeout
