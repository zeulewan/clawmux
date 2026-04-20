# ClawMux Lite

Multi-agent AI chat hub. Node.js server + React frontend. 27 agents across 4 backends, one multiplexed WebSocket per browser tab.

## How it works

```
Browser (React app/)  ←→  WebSocket  ←→  Node.js Hub (server.js)  ←→  Backend Processes
                                              │
                                         Config Files
                                        (~/.clawmux/)
```

- One WS connection per browser tab, all agents share it
- Each agent gets a `ProviderSession` that owns the backend connection
- Agents persist across browser disconnects (processes stay alive, `sendFn` re-attached on reconnect)
- Adding a backend: drop `*-provider.js` in `server/providers/`, add `backends.json` entry

## Files

```
server.js                        ← Express + WS server, agent routing, API endpoints
monitor.js                       ← CLI monitor TUI (SSE-backed, 3Hz, alt screen)
cli.js                           ← cmx CLI (start/stop/restart/monitor/agents/send/config/version)
server/
  config.js                      ← Reads ~/.clawmux/{agents,backends,sessions}.json
                                   Auto-creates defaults on first run. Validates backend/model.
  provider-session.js            ← ProviderSession class: one per agent, translates
                                   provider events → Claude-style io_message envelopes.
                                   Tracks live state for monitor (status/tool/activity).
  sessions.js                    ← Reads Claude CLI session .jsonl files from disk
  usage-poller.js                ← Polls Anthropic OAuth API for 5h/7d rate limits
  providers/
    provider.js                  ← Auto-discovers *-provider.js, registers by name
    events.js                    ← Normalized event types (E.textDelta, E.toolStart, etc.)
    claude-provider.js           ← Spawns `claude -p` per agent, stream-json over stdio
    codex-provider.js            ← Shared `codex app-server` on port 4500, JSON-RPC over WS
                                   Supports thread/resume for session persistence.
    pi-provider.js               ← Spawns `pi --mode rpc` per agent, JSONL over stdio
    opencode-provider.js         ← Shared `opencode serve` on port 4499, HTTP + SSE
                                   Tracks reasoning partIDs for thinking block rendering.
app/                             ← React frontend (Vite)
  src/
    main.jsx                     ← Entry point
    lib/ws.js                    ← Stateless WS client, crypto.randomUUID polyfill
    lib/protocol.js              ← Wraps WS into async API: send(), request(), on()
    state/session.js             ← Single session: messages, busy, error, permissions
    state/sessions.js            ← Session manager: switchToAgent(), create/resume,
                                   per-agent per-backend session persistence.
                                   Server config is source of truth for backend/model.
    components/Sidebar.jsx       ← Agent list, backend badge + switcher
    components/SessionView.jsx   ← Main chat view, top bar (agent/backend/model/usage)
    components/InputBar.jsx      ← Text input, /new, /clear, /model slash commands
    components/MessageList.jsx   ← User + assistant messages
    components/ToolUseContent.jsx ← Tool call cards
    components/ThinkingBlock.jsx ← Collapsible reasoning blocks
tests/
  ui.spec.js                    ← 10 desktop UI tests
  reliability.spec.js           ← 13 reliability regression tests
  mobile.spec.js                ← 3 mobile viewport tests
```

## Config (~/.clawmux/)

All auto-created on first run if missing.

| File | Purpose |
|------|---------|
| `agents.json` | Agent list + per-agent backend/model/effort |
| `backends.json` | Backend definitions (models, labels, effort levels, commands) |
| `sessions.json` | Session registry: agent → backend → sessionId |
| `agents/{name}/` | Per-agent workspace (CLAUDE.md, project files) |

## WS Protocol

All messages are JSON over one WebSocket at `/ws/chat`.

```
Browser → Server:
  switch_agent    { agentId }                    ← focus an agent
  launch   { channelId, resume? }         ← start/resume session
  io_message      { channelId, message }         ← send user message
  interrupt { channelId }                 ← abort current turn
  request         { requestId, request }         ← RPC (get_claude_state, list_sessions, etc.)

Server → Browser:
  io_message      { channelId, message }         ← all events (Claude envelope format):
    message_start, content_block_start, content_block_delta,
    content_block_stop, result, system
  response        { requestId, response }        ← RPC responses
  close_channel   { channelId, error? }          ← session ended
```

Server reads backend/model from agents.json at launch time — frontend doesn't send provider/model.

## Provider interface

Every `*-provider.js` exports a class with:

```js
class FooProvider {
  name = 'foo';                           // matches backends.json key
  async connect(config) → conn            // { cwd, model, resume, effortLevel, agentId }
  send(conn, message)                     // send user text
  interrupt(conn)                         // abort current turn
  onEvent(conn, callback) → unsubscribe   // listen for E.* events
  respondPermission(conn, requestId, ok)  // respond to permission request
  close(conn)                             // tear down
}
```

All providers emit the same event types from `events.js`. `provider-session.js` translates them into Claude-style `io_message` envelopes — the frontend only speaks one protocol.

All providers write JSONL session files to `~/.claude/projects/{hash}/` for history persistence across page reloads.

## API

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/config` | GET | Full config (agents + backends + sessions) |
| `/api/agents` | GET | Agent map |
| `/api/status` | GET | Running agents + PIDs |
| `/api/monitor` | GET | Agent states snapshot |
| `/api/monitor/stream` | GET | SSE stream of state changes |
| `/api/usage` | GET | Anthropic rate limit stats |
| `/api/agents/:id/backend` | POST | Change backend (resets model to default) |
| `/api/agents/:id/model` | POST | Change model (validates against backend) |
| `/api/agents/:id/effort` | POST | Change effort level |
| `/api/send` | POST | Inter-agent messaging |
| `/api/terminate` | POST | Kill an agent's session |

## CLI

```
cmx start                       Start server + auto-resume agents
cmx stop                        Stop server
cmx restart                     Restart + auto-resume agents with saved sessions
cmx restart --hard              Restart without auto-resume (clean slate)
cmx status                      Check if running
cmx monitor                     Live dashboard (3Hz, alt screen, auto-reconnect)
cmx agents                      List all agents with backend/model/status
cmx send <agent> <msg>          Send message to an agent
cmx config                      Show config summary
cmx logs                        Run server in foreground
cmx version                     Versions (clawmux + all backend CLIs)
```

## Key design decisions

1. **Server-authoritative** — agents.json is single source of truth for backend/model/effort. Frontend derives, never stores.
2. **Multiplexed WS** — one connection, all agents. No reconnect on agent switch.
3. **Config-driven** — agents, backends, models, labels all from JSON, not code.
4. **Auto-discovery** — provider.js scans for `*-provider.js` files. Drop a file, add config, done.
5. **Normalized events** — all 4 backends emit the same `E.*` event types. One translation layer.
6. **Workspace per agent** — `~/.clawmux/agents/{name}/` with CLAUDE.md for identity.
7. **Session persistence** — per-agent per-backend session IDs in agents.json. Resume works across page reloads for all 4 backends.
8. **Auto-resume** — on server restart, all agents with saved sessions re-launch automatically. `--hard` flag skips this.
9. **Monitor state tracking** — ProviderSession tracks status/tool/activity per agent, pushed via SSE. Monitor auto-reconnects on server restart.

## Backend capabilities

| Feature | Claude | Codex | pi | OpenCode |
|---------|--------|-------|----|----------|
| Thinking/reasoning | Yes (extended thinking) | No (hidden by API) | Yes (thinking_start/delta/end) | Yes (reasoning parts) |
| Session resume | `--resume` flag | `thread/resume` RPC | `--session` flag | Stale → retry fresh |
| Session history | JSONL (native) | JSONL (written by provider) | JSONL (written by provider) | JSONL (written by provider) |
| Context % tracking | Yes (usage poller) | Yes (tokenUsage/updated) | Yes (turn_end usage) | No |
| Rate limits (5h/7d) | Yes (Anthropic OAuth API, 5min poll) | Yes (account/rateLimits/updated) | No | No |
| Tool calls | Full (stream-json) | Full (JSON-RPC) | Full (JSONL events) | Full (HTTP+SSE) |
| Effort levels | low/medium/high/max | low/medium/high/xhigh | low/medium/high/xhigh | No |
| Model discovery | Static (well-known) | `model/list` RPC at startup | `pi --list-models` at startup | Static |
| Process model | 1 per agent | Shared daemon :4500 | 1 per agent | Shared daemon :4499 |
| Live model name | From config | From config | From `get_state` response | From config |

## Known limitations

- No real session delete — `delete_session` is a no-op (sessions persist on disk)
- Codex reasoning tokens hidden by OpenAI API — thinking dropdown suppressed
- `claude-*` localStorage key prefix still present (cosmetic)
