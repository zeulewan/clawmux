# Multi-Backend Support Brief

*Created: 2026-03-12*

How ClawMux will support multiple AI coding agents — not just Claude Code.

## The Problem

ClawMux was built around Claude Code. Every agent that spawns runs the same CLI, uses the same hooks, and has no way to opt into a different runtime. This creates two real limitations:

**Lock-in.** You cannot run a GPT-5 agent or a local Qwen model alongside your Claude agents. Every agent costs Anthropic tokens regardless of the task.

**Tmux fragility.** Message delivery works by injecting keystrokes into a terminal — the equivalent of typing on behalf of the agent. This is why stuck buffers happen. The whole stuck-buffer monitor exists because this approach is inherently fragile.

## The Landscape Has Changed

Three other CLI coding agents have emerged with hook systems mature enough to integrate with ClawMux:

| CLI | Open Source | Hooks Maturity | Message Delivery |
|---|---|---|---|
| Claude Code | No | Mature (HTTP + command) | Tmux only |
| Gemini CLI | Yes (Apache 2.0) | Mature (nearly identical to Claude Code) | Tmux only |
| Codex CLI | Yes (Apache 2.0) | Growing (SessionStart, Stop, AfterToolUse) | JSONL SDK |
| OpenCode | Yes (MIT) | Rich (25+ plugin events) | HTTP REST API |

OpenCode is the most interesting target: it runs a local HTTP server (`opencode serve`) that accepts messages directly over REST. No tmux injection needed at all.

## What Changes

### The Backend Abstraction

The infrastructure is already in place. `server/backends/base.py` defines a six-method interface every backend must implement: `spawn`, `terminate`, `deliver_message`, `restart`, `capture_pane`, `health_check`. Only `ClaudeCodeBackend` exists today. Adding OpenCode means implementing `OpenCodeBackend` where `deliver_message` is an HTTP POST instead of a tmux keystroke.

### Spawning an Agent

The spawn dialog gains two new fields when creating an agent:

- **Backend** — Claude Code / OpenCode / Gemini CLI
- **Model** *(OpenCode only)* — Claude Opus, GPT-5, Gemini 3, Local (Ollama), etc.

Everything else is unchanged: name, voice, role, folder.

### The Sidebar

Each agent card shows a small backend badge. Claude Code agents look exactly as they do today. OpenCode agents display their underlying model name (e.g. `gpt-5`, `qwen-local`) instead of `opus`/`sonnet`. A subtle icon distinguishes the backend type.

### Settings

A new **Providers** section sits alongside the existing Anthropic / TTS / STT config:

- OpenAI API key (for GPT models in OpenCode)
- Google API key (for Gemini in OpenCode)
- Ollama URL (for local models)

Per-agent model overrides are stored in `agents.json` alongside the existing `model` and `backend` fields.

## Seamless Model Switching

When an agent switches backends — or when you restart an agent that was previously running a different model — the new model needs to catch up on what it missed. Today this is crude: the hub dumps a generic context summary every time an agent restarts, regardless of whether it actually needs one.

The new design is smarter:

### The Last-Writer Check

`history.json` gains a `last_writer_model` field, updated every time a model appends a message. On startup, the hub compares `last_writer_model` to the current model:

- **Match** — the same model was last to write. Its context window already has the conversation (via native session resume). Skip the injection.
- **No match** — a different model wrote last. This model needs to catch up.

### Catch-Up Context

When catch-up is needed, the hub builds a filtered summary of the last N messages (default 30) and prepends it to the agent's first turn as a system block.

The filter is important: **tool calls are stripped**. The catch-up only contains human-readable conversation — user messages and assistant text. No `Bash(...)` calls, no tool inputs, no bare acks. Just the chat.

The goal is that from the agent's perspective, there was no interruption. It reads the context, understands where things stand, and responds as if it had been there all along.

```
history.json
{
  "last_writer_model": "claude-opus-4-6",
  "messages": [...],
  ...
}
```

On startup with GPT-5:
1. Hub sees `last_writer_model` ≠ `gpt-5`
2. Generates filtered catch-up of last 30 conversational messages
3. Injects as system block before first user message
4. Agent responds — and updates `last_writer_model` to `gpt-5`

If Claude Opus resumes next time, same check — it was not last to write — so it gets a catch-up of what GPT-5 said.

## Implementation Plan

### Phase 1 — Foundation (2–3 days)
- `OpenCodeBackend` class: spawn, terminate, deliver_message (HTTP POST), capture_pane
- Bridge TypeScript plugin: translates OpenCode hook events to `POST /api/hooks/tool-status`
- `opencode.json` template generation (replaces `CLAUDE.md` for OpenCode agents)
- `last_writer_model` field in `history_store.append()`
- `generate_catchup_context(model_id, n=30)` method in `HistoryStore`

### Phase 2 — Startup Integration (1 day)
- On agent adopt: call `generate_catchup_context`, prepend to first injection if non-None
- Works identically for Claude Code and OpenCode backends
- Skip injection if Claude Code `--resume` detects native session match

### Phase 3 — UI (1–2 days)
- Spawn form: backend dropdown + model picker
- Sidebar badge: backend icon + model name for non-Claude-Code agents
- Settings panel: provider API key fields

### Phase 4 — Gemini CLI Backend (1–2 days)
Gemini CLI hook protocol is nearly identical to Claude Code (same JSON format, same exit-code semantics, `BeforeToolSelection` → `PreToolUse`, `AfterTool` → `PostToolUse`). A `GeminiBackend` requires:
- Different spawn command (`gemini` instead of `claude`)
- `GEMINI.md` template instead of `CLAUDE.md`
- Adapted `tool-status.sh` hook for Gemini event names

## What Stays the Same

The entire messaging layer, groups, history storage format, TTS, WebSocket protocol, iOS app, and hub logic are untouched. Agents using different backends appear identical in the browser UI aside from their sidebar badge. From the user's perspective, a GPT-5 agent and a Claude Opus agent look and feel the same — they just have different names next to their voice avatar.

## Current Status

Backend abstraction is in place. `ClaudeCodeBackend` is the only implementation. The `last_writer_model` feature and `OpenCodeBackend` are not yet built. Phase 1 is estimated at 2–3 days and is the prerequisite for everything else.
