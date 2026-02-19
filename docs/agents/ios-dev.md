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

See `docs/agents/reference/ui-behavior.md` for the exact behavior of every feature.

## Connection Details

The hub runs on the user's workstation, accessed via Tailscale:

- **WebSocket**: `wss://{hostname}.ts.net:3460/ws`
- **REST API**: `https://{hostname}.ts.net:3460/api/...`
- Single client connection (last-wins) — if browser is open, app replaces it

## Audio Format

- **Playback**: Hub sends base64-encoded MP3
- **Recording**: Browser sends base64-encoded WebM/Opus. The hub passes this to Whisper STT which accepts webm. Other formats may work if Whisper supports them.
