# Early Releases (v0.0.1 – v0.4.0)

---

# v0.0.1 - Initial Release

Initial release — standalone FastAPI server using the Claude API directly.

## Features

- [x] **Claude API integration** — Used the Anthropic Python SDK (`anthropic.Anthropic()`) to call Claude Sonnet 4.5 directly. Each message was a new API call with conversation history passed in.
- [x] **FastAPI REST endpoints** — Browser communicated via HTTP POST to `/api/transcribe`, `/api/chat`, and `/api/speak`.
- [x] **Browser client** — Hold-to-talk mic button, audio playback, conversation managed client-side in JavaScript.
- [x] **Whisper STT + Kokoro TTS** — GPU-accelerated speech services on localhost.

## Limitations

- **API costs** — Every message was a direct Claude API call, adding up quickly.
- **No tool access** — Claude could only chat, not use tools or access the filesystem.

## Superseded Architecture

After v0.0.1, an intermediate approach using `claude -p` (Claude Code CLI pipe mode) was tried but never committed. Each invocation loaded all skills and MCP servers from scratch, making it extremely slow. This was abandoned in favor of the persistent MCP server in v0.1.0.

---

# v0.1.0 - MCP Rewrite

Architecture rewrite — replaced HTTP proxy with MCP server + WebSocket bridge.

## Features

- [x] **MCP server architecture** — Replaced HTTP proxy with FastMCP stdio server that communicates directly with Claude Code.
- [x] **WebSocket bridge** — Embedded FastAPI + WebSocket server for real-time browser audio exchange.
- [x] **Logging** — Dual logging to stderr and `/tmp/clawmux-mcp.log`.
- [x] **Port retry** — Server retries every 5 seconds if port is in use.
- [x] **Integration tests** — Test suite for server functionality.

---

# v0.2.0 - Voice Modes

Released features and improvements.

## Features

- [x] **MCP server + WebSocket bridge** — Single-process server with FastMCP stdio transport and embedded FastAPI + WebSocket for browser audio.
- [x] **Browser client** — Vanilla JavaScript UI with tap-to-record mic, connection status indicator, and auto-reconnect.
- [x] **Whisper STT integration** — OpenAI-compatible speech-to-text via whisper.cpp on GPU.
- [x] **Kokoro TTS integration** — OpenAI-compatible text-to-speech via kokoro-fastapi on GPU.
- [x] **Tailscale remote access** — HTTPS + WSS proxy via `tailscale serve` for access from any device on the tailnet.
- [x] **No recording timeout** — Removed 120-second and 60-second timeouts on recording and playback waits.
- [x] **Hardware requirements documentation** — VRAM and RAM usage table in getting started guide.
- [x] **Roadmap and project documentation** — Structured docs site with Zensical, folder hierarchy, and navigation tabs.

---

# v0.3.0 - Multi-Session

Multi-session hub, simplified controls, and background conversation support.

## Hub

- [x] **ClawMux** — Standalone service (`hub.py`) on port 3460 that spawns and manages multiple Claude Code voice sessions from a single browser tab.
- [x] **Session spawning** — Click "New Session" to create a tmux-backed Claude session with auto-configured MCP.
- [x] **Session tabs** — Tab bar with per-session status dots, close buttons, and badge notifications. Tab label shows Kokoro voice name.
- [x] **Chat transcript** — Display user and assistant message text in a scrollable chat view per session.
- [x] **Per-session voice selection** — Dropdown to choose Kokoro TTS voice (Sky, Alloy, Sarah, Adam, Echo, Onyx, Fable) per session. Auto-rotates through unused voices on spawn.
- [x] **Agent identity** — Each session gets a CLAUDE.md with the voice name as its identity. Greets with "Hi, I'm [name]! How can I help?"
- [x] **Dynamic MCP config** — Per-session temp directory with `.mcp.json` so each Claude instance connects to the hub with the correct session identity.
- [x] **Session timeout** — Auto-terminate sessions after 30 minutes of inactivity.
- [x] **Clean session termination** — Closes MCP WebSocket, kills tmux, removes temp dir.
- [x] **Tmux session ID in controls** — Bottom bar shows tmux session name for easy `tmux attach`.
- [x] **Chat persistence** — Chat messages saved to localStorage and restored on page reload.
- [x] **Voice grid landing page** — Grid of voice cards showing connected/available status. Click to spawn or switch to session. Auto-close tab on agent goodbye.

## Controls & Recording

- [x] **Simplified button flow** — Single main button cycles: Record (blue) → Send (green) → Interrupt (orange) → Processing (grey). Cancel button separate.
- [x] **Mic mute** — Toggle to mute microphone input across all sessions.
- [x] **Auto Record toggle** — Auto-start recording after Claude speaks.
- [x] **Auto End (VAD) toggle** — Voice activity detection auto-stops recording on 1.5s silence. Send button always available for early send.
- [x] **Interrupt support** — Tap Interrupt button during audio playback to stop it immediately. Hub receives `playback_done` and proceeds to listen.
- [x] **Cancel recording** — Separate cancel button discards audio and sends silence so hub doesn't hang.
- [x] **Persistent mic stream** — Mic permission acquired once and stream reused. Fixes background tab recording (no re-prompt when unfocused).

## Multi-Session

- [x] **Background audio buffering** — Background sessions buffer TTS audio. Plays on tab switch before resuming conversation.
- [x] **Pause/resume on tab switch** — Switching away pauses audio, switching back resumes from where it stopped.
- [x] **Background pending listen** — If a background session wants mic input, it activates when you switch to that tab.
- [x] **Stop recording on tab switch** — Discards in-progress recording when switching away to prevent cross-session audio.
- [x] **Tab badge notifications** — Badge appears on tabs with pending audio or listen requests.

## Audio

- [x] **Audio feedback cues** — Ascending tone for listening, soft tone for processing, chime for session ready.
- [x] **No recording timeout** — Removed the 120-second timeout on voice recording.
- [x] **Per-session speed control** — Adjustable TTS speed (0.75x–2x) per session.
- [x] **Voice interrupt** — Interrupt Claude by speaking instead of tapping the button. VAD detects speech during playback, stops audio, and starts recording immediately. Toggle: "Auto Interrupt".
- [x] **Thinking sounds** — Periodic double-tick audio cue via Web Audio API while Claude is processing. Only plays on the focused session tab.
- [x] **Thinking indicator in chat** — Animated pulsing dots in the chat transcript while Claude is processing. Disappears when the agent responds.

## Debug

- [x] **Inline debug panel** — Debug tab showing hub info, service connectivity, active sessions, tmux sessions, and log tail. Auto-refreshes every 5 seconds.

## Branding & Docs

- [x] **Favicon and tab title** — Custom SVG mic favicon, tab title "ClawMux".
- [x] **Human guide** — `docs/guide/overview.md` — what it is, how to use it, controls reference.
- [x] **Agent reference** — `docs/agents/agent-reference.md` — file map, code pointers, endpoints, debugging.

---

# v0.4.0 - iOS App

iOS companion app, browser UI overhaul, and hub reliability fixes.

## iOS Companion App

- [x] **Native Swift app** — Full iOS client with WebSocket connection to the hub, audio playback, recording, and conversation display.
- [x] **Three input modes** — Auto voice (hands-free), Push-to-Talk, and Typing mode with per-mode settings.
- [x] **Typing mode** — Text input with no TTS/STT. Hub `text_mode` flag skips audio processing.
- [x] **PTT mode** — Hold-to-talk with ZStack-centered mic button.
- [x] **Background voice mode** — Silence keepalive loop with VAD auto-stop for hands-free recording when app is backgrounded.
- [x] **Live Activity** — Mode-aware Dynamic Island and Lock Screen display with `voicehub://mic` deep link.
- [x] **Local notifications** — Sent on `assistant_text` when app is backgrounded.
- [x] **Settings page** — Configurable model, server URL, per-mode sound/haptic toggles, VAD tuning.
- [x] **Thinking indicator** — Shown immediately on `thinking` message from hub.
- [x] **Audio cues** — Thinking sounds, listening cue, processing cue, session ready chime.
- [x] **Spotify compatibility** — Audio session interruption observer pauses silence loop.

## Browser UI

- [x] **Visual overhaul** — Dark/light mode with CSS custom properties, iOS-style design language, safe area support.
- [x] **Voice grid landing page** — Grid of voice cards with live session status, spawning feedback, and click-to-connect.
- [x] **Home tab** — Navigate back to voice grid without losing sessions.
- [x] **Settings panel** — Model selection, auto-record, auto-end, auto-interrupt toggles.
- [x] **Debug panel** — tmux sessions table, hub log viewer, Kill All Sessions button.
- [x] **Text input mode** — Type messages to the agent instead of speaking.
- [x] **Thinking sounds** — Double-tick audio pattern while agent processes.
- [x] **Chat persistence** — Messages saved to localStorage and restored on reload.

## Hub Improvements

- [x] **Goodbye parameter** — `converse()` accepts `goodbye=true` to explicitly end sessions. Prevents premature `session_ended` on `wait_for_response=false` calls.
- [x] **Thinking signal** — Hub sends `thinking` message at start of `handle_converse` so clients show immediate feedback.
- [x] **Session timeout** — Increased to 120 minutes.
- [x] **Resilient converse flow** — v0.3.1 improvements to error handling and faster session spawning.
- [x] **Multi-client broadcast fix** — `send_to_browser` iterates over `list(browser_clients)` to avoid set-changed-during-iteration errors.
- [x] **No-cache headers** — Index route sends `Cache-Control: no-cache` so browsers always get fresh HTML.

## Audio Fixes

- [x] **Safari autoplay** — Switched from `new Audio()` to Web Audio API (`audioCtx.decodeAudioData`) so second+ voice responses play on iOS Safari.
- [x] **Repeated listening cue** — Added `pendingListenSessionId` guard to ignore re-sent listening messages.
- [x] **Listening cue cooldown** — 2-second cooldown prevents rapid-fire cue sounds.
- [x] **VAD grace period** — 0.8s delay to ignore audio cue bleedthrough on mic open.

## Documentation

- [x] **CLAUDE.md** — Added project instructions warning about hub.html syntax fragility.
- [x] **Conversation dynamics** — New doc explaining the converse cycle, message flow, and who controls what.
- [x] **Agent reference docs** — WebSocket protocol, UI behavior reference, iOS dev and web dev guides.
