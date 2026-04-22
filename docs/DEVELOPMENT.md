# Development Guide

Everything you need to work on ClawMux. Read this before touching anything.

## Architecture

```
Browser (React)  <-->  WebSocket /ws/chat  <-->  Node.js server  <-->  Backend CLIs
                                                      |
                                                 ~/.clawmux/
                                               agents.json (agents + settings + sessions)
                                               backends.json (backend definitions)
```

- **Server-authoritative**: `agents.json` is the single source of truth for backend/model/effort per agent
- **One WS per browser tab**, all agents multiplexed via agentId
- **ProviderSession**: one per agent, translates provider events into `io_message` envelopes
- **Provider auto-discovery**: drop `*-provider.js` in `server/providers/`, add `backends.json` entry
- **Model auto-discovery**: pi runs `pi --list-models`, codex queries `model/list` RPC at startup, writes to `backends.json`
- **Session persistence**: JSONL files per session in `~/.claude/projects/{hash}/`, session IDs stored per-agent per-backend in `agents.json`
- **Auto-resume**: on server start, all agents with saved sessions re-launch automatically (`--hard` flag skips this)

## Key Files

```
server.js                          Main server — Express + WS + API + monitor SSE
server/config.js                   Config loader — agents.json + backends.json, validation, session registry
server/provider-session.js         ProviderSession class — event translation, state tracking, connection reuse
server/providers/claude-provider.js    Spawns claude -p per agent, stream-json over stdio
server/providers/codex-provider.js     Shared codex app-server on :4500, JSON-RPC over WS, thread/resume
server/providers/pi-provider.js        Spawns pi --mode rpc per agent, JSONL over stdio
server/providers/opencode-provider.js  Shared opencode serve on :4499, HTTP + SSE
server/providers/provider.js       Auto-discovery registry
server/providers/events.js         Normalized event types (E.textDelta, E.toolStart, etc.)
server/sessions.js                 Reads session .jsonl files
server/usage-poller.js             Polls Anthropic OAuth API for 5h/7d rate limits (every 5 min)
monitor.js                         CLI monitor TUI — SSE-backed, 3Hz, alt screen buffer
cli.js                             cmx CLI — start/stop/restart/monitor/agents/send/config/version

app/src/lib/ws.js                  Stateless WS client, crypto.randomUUID polyfill, auto-reconnect
app/src/lib/protocol.js            Async API over WS: launchAgent(), sendMessage(), interrupt(), getAgentState()
app/src/state/session.js           Single session: messages, busy, error, loadMessages()
app/src/state/sessions.js          Session manager: switchToAgent(), createNewSession(), changeBackend/Model
app/src/components/SessionView.jsx Top bar (agent/backend/model/usage), chat container
app/src/components/Sidebar.jsx     Agent list, backend badges, right-click terminate
app/src/components/InputBar.jsx    Text input, slash commands, permission modes
```

## WS Protocol

```
Browser -> Server:
  switch_agent    { agentId }
  launch          { agentId, channelId, resume? }
  io_message      { agentId, channelId, message }
  interrupt       { channelId }
  request         { requestId, request }    (RPC: get_agent_state, list_sessions, etc.)

Server -> Browser:
  io_message      { channelId, message }    (message_start, content_block_start/delta/stop, result, system)
  response        { requestId, response }
  close_channel   { channelId, error? }
  agent_message   { from, to, text, msgId } (inter-agent messaging notification)
```

## Adding a New Provider

```js
// server/providers/foo-provider.js
class FooProvider {
  name = 'foo';
  async connect(config) -> conn     // { cwd, model, resume, effortLevel, agentId }
  send(conn, message)              // user text
  interrupt(conn)
  onEvent(conn, cb) -> unsub        // emits E.* events from events.js
  respondPermission(conn, id, ok)
  close(conn)
}
```

Then add a `foo` entry to `backends.json`. The provider registry auto-discovers it.

## Backend Capabilities

| Feature | Claude | Codex | pi | OpenCode |
|---------|--------|-------|----|----------|
| Thinking | Yes (extended) | No (hidden) | Yes (thinking_start/delta/end) | Yes (reasoning parts) |
| Context % | Yes (API poll) | Yes (tokenUsage) | Yes (turn_end usage) | No |
| Rate limits 5h/7d | Yes (OAuth API) | Yes (rateLimits/updated) | No | No |
| Session resume | --resume flag | thread/resume RPC | --session flag | Stale -> retry fresh |
| Model discovery | Static | model/list RPC | pi --list-models | Static |
| Process model | 1 per agent | Shared daemon :4500 | 1 per agent | Shared daemon :4499 |

## Config Files (~/.clawmux/)

**agents.json** — agents + per-agent settings + session IDs:
```json
{
  "defaults": { "backend": "claude", "model": "claude-opus-4-7", "effort": "high" },
  "agents": [
    { "name": "Agent1", "backend": "claude", "model": "claude-opus-4-7",
      "sessions": { "claude": "uuid-1", "codex": "uuid-2" } }
  ]
}
```

**backends.json** — backend definitions (auto-populated for pi/codex at startup):
```json
{
  "_default": "claude",
  "claude": { "enabled": true, "models": [...], "effortLevels": [...], "commands": [...] },
  "codex": { ... },
  "pi": { ... },
  "opencode": { ... }
}
```

## Critical Behaviors

### Connection Reuse
When an agent is already running (from auto-resume or another tab), `launchProvider` reuses the existing connection instead of killing/respawning. It remaps the channelId and re-subscribes event listeners.

### Resume Retry
All backends handle stale session IDs:
- **Claude**: stderr "No conversation found" -> `resume_failed` -> relaunch fresh
- **Pi**: stderr "No session found" -> `resume_failed` -> relaunch fresh
- **Codex**: `thread/resume` RPC error -> `resume_failed` -> relaunch with `thread/start`
- **OpenCode**: `prompt_async` 400/404 -> `resume_failed` -> relaunch fresh

### Backend Switching
`POST /api/agents/:id/backend` updates config, resets model to `'default'`, kills active session. Next `launch` spawns the new backend.

### Monitor State Machine
`offline -> idle -> thinking -> responding -> tool_call -> error -> offline`
- Starts `offline` — only goes online after `launchProvider`
- Health check (30s) relaunches agents in `offline` or `error` state
- Stale stream watchdog (120s) catches dead connections

### Session History
All backends write JSONL to `~/.claude/projects/{hash}/{sessionId}.jsonl`. Claude redacts thinking content in saved sessions — provider-session writes a `thinking_cache` entry to preserve it.

## CLI Reference

```
cmx start              Start + auto-resume
cmx stop               Stop
cmx restart            Restart + auto-resume
cmx restart --hard     Clean restart (no auto-resume)
cmx monitor            Live dashboard (3Hz, alt screen, auto-reconnect)
cmx agents             List agents + status
cmx send <agent> <msg> Inter-agent message (sender auto-detected)
cmx send --close-thread <agent>
                       Close a peer thread without injecting a reply-provoking prompt
cmx send --reopen-thread <agent> <msg>
                       Reopen a closed peer thread and send a fresh opener
cmx launch <agent>     Launch or restart an agent
cmx terminate <agent>  Stop a running agent
cmx doctor             System health check
cmx config             Config summary
cmx update             Git pull + rebuild + restart
cmx version            Versions + commit hash
cmx logs               Foreground server with visible output
cmx help               Full reference
```

## Testing

Playwright tests in `tests/`. Run with `npm test`. Video + screenshots on failure.

## Known Limitations

- **OpenCode model discovery** — no API found, models are static in backends.json
- **OpenCode sender auto-detect** — shared daemon ignores per-session cwd, agents show as `from:cli`
- **Session transfer between backends** — switching backends starts fresh, no conversation content transfer
- **Pi concurrency** — pi can't reliably run many concurrent instances; some may die on startup
