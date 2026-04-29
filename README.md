# ClawMux Lite

Multi-agent AI chat hub. 27 agents, 4 backends (Claude, Codex, pi, OpenCode), one browser tab.

## Install

```bash
git clone https://github.com/zeulewan/clawmux-lite.git && cd clawmux-lite
npm install
cd app && npm install && cd ..
```

## Run

```bash
npm start          # builds frontend + starts server
# or
npm run dev        # skip build, use existing dist (faster restart)
```

Server runs on `http://localhost:3470`.

To access from other devices (e.g. over Tailscale):

```bash
HOST=0.0.0.0 cmx start          # bind to all interfaces
HOST=100.x.x.x cmx start        # bind to specific IP (e.g. Tailscale)
```

## Config

All config lives in `~/.clawmux/`. On first run, default config files are auto-created.

```
~/.clawmux/
  agents.json      ← agent list + per-agent backend/model/effort
  backends.json    ← backend definitions (models, labels, effort levels)
  agents/
    adam/           ← per-agent workspace (CLAUDE.md, files)
    emma/
    ...
```

### Backends

| Backend  | CLI                | Pattern      | Thinking    | Context %          | Rate Limits | Models          |
| -------- | ------------------ | ------------ | ----------- | ------------------ | ----------- | --------------- |
| Claude   | `claude`           | 1 per agent  | Yes         | Yes (API poll)     | Yes (5h/7d) | Static          |
| Codex    | `codex app-server` | Shared :4500 | No (hidden) | Yes (token events) | Yes (5h/7d) | Auto-discovered |
| pi       | `pi --mode rpc`    | 1 per agent  | Yes         | Yes (turn_end)     | No          | Auto-discovered |
| OpenCode | `opencode serve`   | Shared :4499 | Yes         | No                 | No          | Static          |

Switch backend per agent: click the badge in the sidebar.

Backend/model validation: setting a model rejects values not valid for the agent's backend. Switching backends auto-resets the model to the new backend's default.

### Models

Models are defined per backend in `backends.json`. The `/model` menu in the UI reads from there.

## CLI

```bash
cmx start              # start server (daemonized), auto-resumes agents
cmx stop               # stop server
cmx restart            # restart + auto-resume all agents with saved sessions
cmx restart --hard     # restart without auto-resume (clean slate)
cmx status             # check if running
cmx monitor            # live agent status dashboard (3Hz, alt screen)
cmx agents             # list all agents with backend/model/status
cmx send <agent> <msg> # send message to an agent
cmx send --close-thread <agent>        # end a peer thread without provoking a reply
cmx send --reopen-thread <agent> <msg> # reopen a closed thread and send a fresh message

### Inter-agent threads

Each agent pair shares a thread — a conversation channel that can be open or closed. When an agent closes a thread with `--close-thread`, further sends to that agent are blocked until `--reopen-thread` is used.

This prevents reply loops: without thread control, Agent A responds, Agent B says "got it", Agent A says "great", and so on indefinitely. Closing the thread signals the conversation is done. Agents should close threads when wrapping up and only reopen them for genuinely new topics.
cmx config             # show config summary
cmx logs               # run server in foreground (see stdout)
cmx update             # git pull + rebuild + restart
cmx version            # show versions (clawmux + all backend CLIs)
cmx help               # full command reference
```

### Agent persistence

Agents auto-resume on server restart. Session IDs stored in `agents.json` are used to re-launch each agent with its previous session. The browser reconnects via WS and picks up where it left off. Use `cmx restart --hard` for a clean restart without auto-resume.

### Monitor

`cmx monitor` opens a live dashboard showing all agents:

- Status: offline, idle, thinking, responding, tool_call, error
- Current tool name when active (Bash, Edit, Read, etc.)
- Thinking / effort level per agent
- Context window usage (%) per agent
- Backend, model, session ID, last activity
- Anthropic and OpenAI rate limits (5h/7d) in footer
- 3Hz refresh, alternate screen buffer (no scroll growth)
- SSE-backed: server pushes state changes in real-time
- Auto-reconnects if server restarts

### API

| Endpoint                  | Method | Description                     |
| ------------------------- | ------ | ------------------------------- |
| `/api/agents`             | GET    | List all agents with config     |
| `/api/config`             | GET    | Full config (agents + backends) |
| `/api/status`             | GET    | Running agents + PIDs           |
| `/api/monitor`            | GET    | Agent states snapshot           |
| `/api/monitor/stream`     | GET    | SSE stream of state changes     |
| `/api/usage`              | GET    | Anthropic usage stats           |
| `/api/agents/:id/backend` | POST   | Change agent backend            |
| `/api/agents/:id/model`   | POST   | Change agent model              |
| `/api/agents/:id/effort`  | POST   | Change agent effort level       |
| `/api/send`               | POST   | Inter-agent messaging           |
| `/api/terminate`          | POST   | Kill an agent's process         |

## Inter-agent messaging

```bash
curl -X POST http://localhost:3470/api/send \
  -H 'Content-Type: application/json' \
  -d '{"from":"am_adam","to":"am_echo","text":"hello"}'
```

## Auth

Each backend manages its own auth:

- **Claude**: `claude` CLI login (Max subscription)
- **Codex**: `codex login --device-auth` (ChatGPT Pro)
- **pi**: `pi` then `/login` (subscription or API key)
- **OpenCode**: `opencode auth login` (provider-specific)

## Architecture

- Server-authoritative state: `agents.json` is the single source of truth for backend/model/effort
- Frontend has one store object with per-agent session Map — sessions persist across agent switches
- WebSocket at `/ws/chat` — one connection per browser tab, all agents multiplexed
- All 4 providers emit normalized events (`E.*`), translated to Claude-style `io_message` envelopes
- Provider auto-discovery: drop `*-provider.js` in `server/providers/`, add entry to `backends.json`

## Slash commands

- `/new` — start a fresh conversation
- `/clear` — clear chat history (same as /new)
- `/model` — switch model for current agent

## Security

**ClawMux has no authentication.** Anyone who can reach the server has full access to all agents, sessions, and tools.

- By default the server binds to `127.0.0.1` (localhost only)
- If you set `HOST=0.0.0.0`, the server is exposed to your entire network — only do this on trusted networks (e.g. Tailscale)
- `~/.clawmux/` contains session data and config — ensure directory permissions are `700` (user-only)
- Claude agents run with `--dangerously-skip-permissions` — they can execute any command without confirmation
- There is no CORS validation, rate limiting, or request authentication on the API

This is a local development tool, not a production service. Do not expose it to untrusted networks without adding an authentication layer.

## Notes

- Agents persist across browser disconnects — close tab, reopen, pick up where you left off
- Sessions stored in `~/.claude/projects/{hash}/*.jsonl` (Claude CLI format)
- Thinking/chain-of-thought: only visible for Claude backend (extended thinking). Codex reasoning tokens are hidden by OpenAI's API.
