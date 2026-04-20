# ClawMux TODO

## Bugs

- **OpenCode double events** — deduplicated but may still fire extra `message_start` in edge cases

## Important

- **OpenAI usage polling** — Codex pushes rate limits inline but no idle polling like Anthropic. Need to find/reverse-engineer ChatGPT Pro usage endpoint.

## Features to port from OpenClaw

See memory file `clawmux_drop_openclaw.md` for full plan. Summary:

### Tier 1 (core)
- System prompt layering (user global → agent identity → workspace local)
- Memory system (MEMORY.md + typed memory files, auto-loaded)

### Tier 2
- BOOT.md hook (per-agent startup checklist)
- Heartbeat (periodic HEARTBEAT.md read)
- Cron (scheduled agent tasks)

### Tier 3
- Realtime voice
- ACP (richer inter-agent protocol)

## Nice to have

- **Settings/debug panel** — frontend panel showing per-agent status, connection state, event counts
- **Session delete** — actually delete session files instead of no-op
- **Session history cleanup** — clear stale error messages from failed resume attempts

## Known limitations

- **Codex reasoning not visible** — Codex app-server sends `item/started type:reasoning` with empty `summary:[]` and `content:[]`, then immediately `item/completed` with the same empty arrays. No `item/reasoning/textDelta` or `summaryTextDelta` notifications are emitted. Reasoning tokens are consumed server-side by OpenAI but never exposed through the protocol. The thinking dropdown is suppressed for Codex (lazy open — only shown if actual deltas arrive).
- **pi/OpenCode thinking** — Neither pi nor OpenCode currently expose chain-of-thought content through their protocols.
