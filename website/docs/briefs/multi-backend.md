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

### The Top Bar

Today the agent header shows a Claude-specific control: `Opus High`, `Sonnet Low`, `Sonnet High Q`, etc. This is hardcoded around Claude Code's model and effort tiers.

With multi-backend support, the top bar becomes **model-agnostic**. It shows the actual model name — `claude-opus-4-6`, `gpt-5`, `gemini-3`, `qwen2.5-coder` — whatever is running. The effort/quality selector only appears when the active backend supports it (Claude Code does; OpenCode's equivalent is picking the model itself).

The key design principle: **the UI is backend-neutral first**. The top bar describes what model is running, not which CLI it runs through. Switching an agent from Claude Opus to GPT-5 changes the label; the rest of the interface is identical.

The sidebar is unchanged.

### Settings

A new **Providers** section sits alongside the existing Anthropic / TTS / STT config:

- OpenAI API key (for GPT models in OpenCode)
- Google API key (for Gemini in OpenCode)
- Ollama URL (for local models)

Per-agent model overrides are stored in `agents.json` alongside the existing `model` and `backend` fields.

## Seamless Model Switching

When an agent switches backends — or when you restart an agent that was previously running a different model — the new model needs to catch up on what it missed. Today this is crude: the hub dumps a generic context summary every time an agent restarts, regardless of whether it actually needs one.

The new design is smarter:

### The Read Cursor

`history.json` gains a `read_cursors` map — one entry per `(agent, model)` pair, storing the index of the last message that model processed. On startup, the hub compares the cursor to the current message count:

- **Cursor at end** — this model has seen everything. Skip injection.
- **Cursor behind** — messages arrived since this model was last active. Inject the delta.

```json
{
  "messages": [...],
  "read_cursors": {
    "claude-opus-4-6": 142,
    "gpt-5": 89
  }
}
```

### Catch-Up Context

The catch-up injects **exactly the messages this model missed** — from its cursor position to the current end of history. If only two messages came in while the model was away, it gets two messages. If fifty came in, it gets fifty.

The cap is **50 messages** (configurable). If the delta exceeds the cap, the most recent 50 are used. The model gets what it needs to be useful right now, not a full replay of everything it ever missed.

The filter is important: **tool calls are stripped**. The catch-up only contains human-readable conversation — user messages and assistant text responses. No `Bash(...)` calls, no tool inputs, no bare acks. Just the chat.

The goal is that from the agent's perspective, there was no interruption. It reads the delta, understands where things stand, and responds as if it had been there all along.

On startup with GPT-5 (cursor at 89, history at 142):
1. Hub computes delta: messages 89–142 = 53 messages
2. Filters to conversational text only: say 31 messages remain
3. Injects as system block before first user message
4. Agent responds — cursor for `gpt-5` advances to 142

If Claude Opus resumes next, its cursor is already at 142 (it was last active). Skip injection.

## Implementation Plan

### Phase 1 — Foundation
- `OpenCodeBackend` class: spawn, terminate, deliver_message (HTTP POST), capture_pane
- Bridge TypeScript plugin: translates OpenCode hook events to `POST /api/hooks/tool-status`
- `opencode.json` template generation (replaces `CLAUDE.md` for OpenCode agents)
- `read_cursors` map in `history_store` — updated on every model write
- `generate_catchup_context(model_id, cap=50)` method in `HistoryStore` — returns delta since cursor, filtered to chat-only, capped at 50

### Phase 2 — Startup Integration
- On agent adopt: call `generate_catchup_context`, prepend to first injection if non-None
- Works identically for Claude Code and OpenCode backends
- Skip injection if Claude Code `--resume` detects native session match

### Phase 3 — UI
- Spawn form: backend dropdown + model picker
- Sidebar badge: backend icon + model name for non-Claude-Code agents
- Settings panel: provider API key fields

### Phase 4 — Gemini CLI Backend
Gemini CLI hook protocol is nearly identical to Claude Code (same JSON format, same exit-code semantics, `BeforeToolSelection` → `PreToolUse`, `AfterTool` → `PostToolUse`). A `GeminiBackend` requires:
- Different spawn command (`gemini` instead of `claude`)
- `GEMINI.md` template instead of `CLAUDE.md`
- Adapted `tool-status.sh` hook for Gemini event names

## What Stays the Same

The entire messaging layer, groups, history storage format, TTS, WebSocket protocol, iOS app, and hub logic are untouched. Agents using different backends appear identical in the browser UI aside from their sidebar badge. From the user's perspective, a GPT-5 agent and a Claude Opus agent look and feel the same — they just have different names next to their voice avatar.

## Current Status

Backend abstraction is in place. `ClaudeCodeBackend` is the only implementation. The read cursor and `OpenCodeBackend` are not yet built. Phase 1 is the prerequisite for everything else.
