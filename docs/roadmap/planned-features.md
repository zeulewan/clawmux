# Planned Features

Items not yet assigned to a release.

## Setup

- [ ] **One-command setup** — single script that installs Whisper, Kokoro, Python venv, MCP server, and Tailscale.
- [ ] **Standalone installs** — install whisper.cpp and kokoro-fastapi directly from upstream with bundled systemd service files, removing the VoiceMode dependency.
- [ ] **Health check endpoint** — `/health` that verifies Whisper, Kokoro, and WebSocket connectivity in one call.

## Audio

- [ ] **Whisper model selection** — choose model size (tiny through large) from the UI for quality vs speed.
- [ ] **Word-level highlight** — highlight text in the chat as it's being spoken, synchronized with TTS playback.

## Browser

- [ ] **Settings panel** — in-browser controls for voice, speed, Whisper model, and other config.
- [ ] **Keyboard shortcut** — press-and-hold spacebar to record on desktop.
- [ ] **Mobile improvements** — optimized touch targets, haptic feedback, wake lock.
- [ ] **Dark/light theme** — match system preference or manual toggle.
- [ ] **Spawn all button** — spawn all voices at once.

## Branding

- [ ] **Rename to Agent Hub** — better reflects multi-agent capabilities beyond just voice.
- [ ] **Liquid Glass design** — adopt Apple's Liquid Glass visual language when iOS 26 launches.

## Documentation

- [ ] **Demo video** — embedded demo on the homepage.
- [ ] **AI-optimized docs** — machine-readable `llms.txt` so LLMs can install autonomously.
- [ ] **API reference** — all MCP tool signatures, WebSocket message types, HTTP endpoints.
- [ ] **Troubleshooting guide** — audio quality, latency, Tailscale connectivity, common failures.
