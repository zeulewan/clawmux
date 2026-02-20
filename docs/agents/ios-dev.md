# iOS Development

You are building a native iOS app that connects to the Voice Hub as a client, replacing the browser UI.

## How It Works

The iOS app connects to the same hub WebSocket as the browser. The hub doesn't care what client is connected — it sends the same messages either way. Your job is to implement the same state machine and audio handling that `static/hub.html` does, but in Swift/SwiftUI.

## Reference Docs

Read these before writing any code:

| Document | What you'll learn |
|----------|-------------------|
| [WebSocket Protocol](reference/protocol.md) | Every message type, the converse flow sequence, session object schema, REST API |
| [UI Behavior](reference/ui-behavior.md) | All states, button behaviors, toggles, audio handling for focused vs background sessions, tab switching |
| [Hub Architecture](reference/hub.md) | How the hub works, what it expects from clients |

The protocol doc is your contract. The UI behavior doc is your spec. The hub.html source is your reference implementation.

## Key Files to Watch

These files define what the app needs to implement. When they change, your implementation may need updating:

```
docs/agents/reference/protocol.md       # WebSocket messages and REST API — your integration contract
docs/agents/reference/ui-behavior.md    # States, controls, audio behavior — your feature spec
static/hub.html              # Reference implementation — how the browser does it
docs/roadmap/v0.3.0.md       # Current release features (what's implemented)
docs/roadmap/v0.4.0.md       # Next release features (what's coming)
```

## What to Implement

The app needs to handle all the same WebSocket messages and user interactions as the browser. Core requirements:

1. **WebSocket connection** to `wss://{host}:{port}/ws`
2. **Session management** — list, spawn (POST), terminate (DELETE), switch between sessions
3. **Audio playback** — decode base64 MP3 from `audio` messages, play through speaker
4. **Audio recording** — record from mic, encode to webm/opus, send as base64 in `audio` messages
5. **State machine** — track session states (starting/ready/active), button states (record/send/interrupt/processing), thinking indicators
6. **Background session handling** — buffer audio for non-focused sessions, show badges, resume on switch
7. **Toggles** — Auto Record, Auto End (VAD), Auto Interrupt, Mic Mute
8. **Voice/speed selection** — per-session, via REST API
9. **Message history** — fetch from `GET /api/history/{voice_id}` when opening a voice's chat, display previous messages. Reset via `DELETE /api/history/{voice_id}`

See `docs/agents/reference/ui-behavior.md` for the exact behavior of every feature.

## Message History

Messages are persisted **server-side per voice** (not per session). When a session is terminated and respawned for the same voice, the conversation history carries over.

- **Fetch history**: `GET /api/history/{voice_id}` → `{"voice_id": "af_sky", "messages": [{"role": "user"|"assistant", "text": "...", "ts": 1708300000.0}, ...]}`
- **Clear history**: `DELETE /api/history/{voice_id}` → `{"status": "cleared", "voice_id": "af_sky"}`
- The hub records messages automatically during `converse()` — clients do NOT need to send messages to be stored
- On session open, fetch history and display it as the chat transcript
- Only display the **last 50 messages** — server stores up to 200 but rendering all is unnecessary
- Provide a "Reset History" action (e.g. in a context menu or swipe action) that calls the DELETE endpoint
- **Reset clears everything** — message history AND the Claude session. The next spawn for that voice starts completely fresh (new Claude context, default greeting)

## Connection Details

The hub runs on the user's workstation, accessed via Tailscale:

- **WebSocket**: `wss://{hostname}.ts.net:3460/ws`
- **REST API**: `https://{hostname}.ts.net:3460/api/...`
- **Multi-client** — multiple clients (browser + iOS app) can connect simultaneously. All receive the same messages.

## Heartbeat & Sync

The hub sends `{"type": "ping"}` to all clients every 30 seconds. Clients that fail to receive it are disconnected. The iOS app should:

- **Ignore `ping` messages** — no response needed, just don't crash on them
- **Detect stale connections** — if no `ping` received for ~60s, reconnect
- **Stay in sync** — all session state changes (status, new messages, audio) are broadcast to every connected client simultaneously. The app doesn't need to poll — just listen to the WebSocket.
- **On reconnect** — hub sends `session_list` on connect, which gives the full current state. Fetch history for each session via `GET /api/history/{voice_id}` to restore chat transcripts.

## Navigation

The app should use a **voice grid** as the landing page (not tabs). Each voice gets a card.

- **Tapping a card with an active session** → switch to its chat view immediately
- **Tapping an inactive card** → spawn via `POST /api/sessions`, stay on the grid showing "Spawning..." state on the card. When a `session_status` message arrives with `status: "ready"` for that session, auto-switch to the chat view.
- **Duplicate voice guard** — the server returns 503 if that voice already has a session. Don't show an error, just ignore it.
- **On app launch or reconnect** — always show the voice grid first, never auto-switch to a session

Show a connection status indicator (pulsing yellow = connecting, green = connected, red = disconnected).

## Settings

Settings are persisted server-side and shared across all clients. The iOS app should:

- **Fetch settings on connect**: `GET /api/settings` → `{"model": "opus", "auto_record": false, "auto_end": true, "auto_interrupt": false}`
- **Update settings**: `PUT /api/settings` with a partial JSON object (e.g. `{"model": "haiku"}`) → returns full settings
- **Sync with web client** — when settings change on one client, the other picks them up on next fetch
- Available models: `opus`, `sonnet`, `haiku` (applies to newly spawned sessions only)
- Provide a settings screen with toggles for auto_record, auto_end, auto_interrupt, and a model picker

## Audio Format

- **Playback**: Hub sends base64-encoded MP3
- **Recording**: Browser sends base64-encoded WebM/Opus. The hub passes this to Whisper STT which accepts webm. Other formats may work if Whisper supports them.
