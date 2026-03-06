# Early Releases (v0.0.1 – v0.4.0)

Condensed history of the first five releases, from standalone API server to multi-session hub with iOS app.

## v0.0.1 — Initial Release

Standalone FastAPI server calling Claude Sonnet 4.5 via the Anthropic SDK. Browser communicated via HTTP POST endpoints (`/api/transcribe`, `/api/chat`, `/api/speak`). Whisper STT + Kokoro TTS on GPU. No tool access — Claude could only chat. Every message was a direct API call.

After v0.0.1, an intermediate `claude -p` (pipe mode) approach was tried but abandoned — each invocation loaded all skills and MCP servers from scratch, making it extremely slow.

## v0.1.0 — MCP Rewrite

Replaced the HTTP proxy with a FastMCP stdio server + WebSocket bridge. Real-time browser audio exchange via embedded FastAPI. Dual logging, port retry, and integration tests.

## v0.2.0 — Voice Modes

Added Tailscale remote access (HTTPS + WSS via `tailscale serve`), removed recording timeouts, hardware requirements documentation, and structured docs site with Zensical.

## v0.3.0 — Multi-Session

Introduced the ClawMux hub (`hub.py`) on port 3460 — a standalone service that spawns and manages multiple Claude Code voice sessions from a single browser tab.

Key features: session tabs with status dots, per-session voice selection (auto-rotating through 7 Kokoro voices), agent identity via CLAUDE.md, dynamic MCP config, session timeout (30 min), chat persistence, voice grid landing page.

Controls: single-button flow (Record → Send → Interrupt → Processing), mic mute, auto-record, VAD auto-end, interrupt support, cancel recording, persistent mic stream.

Multi-session: background audio buffering, pause/resume on tab switch, background pending listen, tab badge notifications.

Audio: feedback cues, per-session speed control, voice interrupt, thinking sounds with animated chat indicator.

Debug: inline panel with hub info, service connectivity, active sessions, log tail.

## v0.4.0 — iOS App

Native Swift companion app with WebSocket connection to the hub.

**iOS features:** three input modes (auto voice, push-to-talk, typing), background voice mode with VAD, Live Activity (Dynamic Island + Lock Screen), local notifications, settings page, thinking indicator, audio cues, Spotify compatibility.

**Browser:** dark/light mode with CSS custom properties, iOS-style design, home tab, settings panel, debug panel, text input mode, thinking sounds, chat persistence.

**Hub:** goodbye parameter for explicit session end, thinking signal, 120-min timeout, resilient converse flow, multi-client broadcast fix, no-cache headers.

**Audio fixes:** Safari autoplay (Web Audio API), listening cue cooldown, VAD grace period.
