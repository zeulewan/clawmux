# OpenClaw Reference

OpenClaw is a self-hosted AI agent platform that could serve as the backend for Voice Hub instead of the current Claude Code + tmux approach. This doc covers what it is, how it works, and what integration would look like.

## What It Is

OpenClaw is an always-on, open-source agent runtime designed to run on your own hardware. A single persistent **Gateway** process (WebSocket on port 18789) routes messages between communication channels (WhatsApp, Telegram, Slack, Discord, iMessage) and AI agent sessions. Agents maintain persistent state, execute tools, browse the web, run code, and operate on schedules — all without human prompting.

It is fundamentally different from Claude Code: Claude Code is a coding assistant optimized for software engineering inside a terminal. OpenClaw is a general-purpose agent platform for life and work automation that also happens to support code execution.

## Architecture

```
Gateway (WebSocket :18789)
├── Messaging adapters — WhatsApp, Telegram, Slack, Discord, iMessage, WebChat
├── Control clients — macOS app, CLI, web UI, automation
└── Agent sessions — isolated per-voice, serialized execution
```

The Gateway is the single control plane. Clients connect via `ws://127.0.0.1:18789` with an initial `connect` frame for auth. Wire protocol: JSON WebSocket frames, request/response + event streaming.

Never expose the Gateway to the internet. Use SSH tunnels or Tailscale for remote access.

## Agent Loop

When a message arrives, the loop runs:

1. Message routed to agent via session binding
2. System prompt assembled — config files (`AGENTS.md`, `SOUL.md`, `TOOLS.md`), matching skills, memory search results
3. Model invoked — streams text and tool calls
4. Tool calls intercepted and executed (bash, file I/O, browser, etc.)
5. Results returned to model; loop continues until response complete
6. Session state persisted to disk

One loop runs at a time per session (serialized). Loop events stream in real-time, so audio can start playing before the response completes.

## Tool Capabilities

| Tool | What it does |
|------|-------------|
| `read` | Read files from the filesystem |
| `write` | Create or overwrite files |
| `edit` | Surgical edits to file sections |
| `exec` | Run bash commands (optionally Docker-sandboxed) |
| `browser` | Chromium automation via Chrome DevTools Protocol |
| `memory_search` | Semantic search over past conversations |
| `session` | Read session history, spawn sub-sessions |
| `agent` | Spawn sub-agents |
| `cron` | Schedule recurring tasks |
| `nodes` | Control iOS/Android devices |

**Skills** are markdown files teaching agents how to combine tools for specific tasks (email, GitHub, Slack, smart home, etc.). Skills are loaded contextually — only relevant ones are injected per turn.

## Multi-Agent Support

Multiple isolated agents run within a single Gateway, each with:

- Separate workspace directory
- Separate auth profile and session store
- Separate tool policies (e.g., read-only agent vs. exec-enabled agent)
- Separate routing rules (map channels/accounts to agents)

Leaders can spawn sub-agents via the `agent` tool. This maps naturally to Voice Hub's leader/worker model.

## Protocol: ACP

ACP (Agent Control Protocol) lets OpenClaw bridge external coding harnesses — Claude Code, Codex, Gemini CLI, Pi. An ACP session binds to a conversation thread; follow-up messages route to the same external harness. You could use OpenClaw for orchestration and voice routing while delegating complex coding tasks to Claude Code via ACP.

## Protocol: MCP

No native MCP support. Workaround: **MCPorter**, a TypeScript toolkit that exposes MCP calls via CLI. Agents call MCPorter through the `exec` tool. Not first-class but functional.

## Models

Model-agnostic. Supports Anthropic (Claude Opus, Sonnet, Haiku), OpenAI (GPT-4, etc.), Google (Gemini), Groq, Mistral, xAI, and local models via Ollama. OpenRouter for multi-provider routing and fallbacks.

Cost: pay per API token. No flat subscription.

## Our Setup

OpenClaw is installed on the workstation (`openclaw` CLI at `~/.npm-global/bin/openclaw`, version 2026.2.26). The Gateway is **not running** on the workstation.

The primary Gateway runs on the Raspberry Pi (`openclaw` hostname, Tailscale 100.81.195.18:18789). That Pi's Tailscale ACL is locked to only the Mac (100.117.222.41) and iPhone — the workstation can't reach it.

To use OpenClaw as a Voice Hub backend on the workstation, we'd need to run the Gateway locally: `openclaw gateway`.

## Integration Approach for Voice Hub

Instead of spawning Claude Code in tmux, Voice Hub would:

1. Start/connect to a local OpenClaw Gateway
2. Create one OpenClaw agent per voice (Sky, Alloy, Adam, etc.) with isolated workspaces
3. Route voice input to the appropriate agent via Gateway WebSocket
4. Stream responses back from the agent loop for TTS
5. Use OpenClaw's native multi-agent for leader/worker orchestration

Frontend stays the same. The session backend abstraction (v0.6.0 dual-backend plan) is the insertion point.

### Tradeoffs vs. Claude Code + tmux

| | Claude Code (current) | OpenClaw |
|---|---|---|
| Model | Claude only | Any (Anthropic, OpenAI, Ollama, …) |
| Pricing | Flat subscription | Per API token |
| Persistence | Session lost on restart | Always-on, persistent state |
| Multi-agent | Our custom implementation | Native (workspaces, bindings) |
| MCP tools | Full, native | Via MCPorter (workaround) |
| Skills/CLAUDE.md | CLAUDE.md files | AGENTS.md, SOUL.md, skills system |
| Code execution | Deep (Claude is code-native) | exec tool + coding-agent skill |
| Visibility | None between converse calls | Full streaming loop events |
| Security | Managed by Anthropic | Self-managed; serious risks if misconfigured |

## Security Notes

OpenClaw went viral in early 2026 and ~21,000 instances were exposed publicly, leaking API keys and getting compromised. Key risks: agents have broad system access (exec, file I/O) and accept input from untrusted channels.

Mitigations: bind Gateway to localhost only, use Tailscale for remote access, restrict per-agent tool policies, sandbox exec in Docker, vet any third-party skills before installing.

For Voice Hub: run Gateway as a local service, not exposed externally. Only Voice Hub's backend talks to it.
