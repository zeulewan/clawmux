# v0.5.0 - Polish & Reliability (Final MCP Release)

Stability, UX polish, and bug fixes. This is the final release using the MCP server architecture.

## Hub

- [x] Adopt orphaned sessions on startup — scan for existing tmux sessions and re-adopt them. `@sky`
- [x] Graceful reload — hub restarts without killing agent sessions, MCP servers auto-reconnect. `@sky` `@fable`
- [ ] Hold-aware timeout — exempt sessions with pending `converse()` calls from inactivity timeout.
- [ ] Streaming TTS — stream audio chunks as Kokoro generates to reduce time-to-first-audio.
- [ ] Configurable STT/TTS URLs — run Whisper and Kokoro on a different machine than the hub.
- [ ] ClawMux CLI — replace MCP server with a CLI tool for voice and inter-agent messaging.

## Browser Bugs

- [x] Voice overlaps — new TTS audio plays over previous audio that hasn't finished. `@sky`
- [x] First word cut off — beginning of TTS playback gets clipped. `@sky`
- [x] Voice doesn't resume when returning to tab — audio stops after tab switch. `@sky`
- [x] Typed messages don't appear in chat — text input sends but isn't rendered. `@sky`
- [x] Messages sent while agent is talking disappear — interjection support added with visual confirmation. `@sky`
- [x] Debug panel overflow — work dir column spills off the edge on narrow screens. `@sky`

## Browser UX

- [x] Session elapsed time — show time since last message. `@adam`
- [x] Copy on long-press — copy chat message text. `@adam`
- [x] Status clarity — "Listening" should only show during active recording. Otherwise show "Ready" or "Idle." Consistent across all states. `@sky`
- [ ] Auto mode cancel — cancel button should temp-pause auto mode, not restart recording.
- [x] Seamless reconnection — hub sends full session state on browser connect so UI syncs immediately. localStorage active-voice restore added. `@sky`
- [ ] Live reload — hub watches `static/hub.html` and triggers browser reload via WebSocket.
- [x] Multi-client support — multiple browser tabs/devices show synchronized state. `@sky`
- [x] Interrupt gesture — Escape key stops playback and cancels recording. `@echo`
- [x] Paste button — paste text into chat input. `@sky`
- [ ] Code block rendering — render code blocks properly in agent responses.
- [x] Pause button — pause/resume voice playback via transport bar. `@sky`
- [x] Sidebar navigation — persistent sidebar with compact voice cards, status dots, unread indicators. `@sky`
- [x] Disconnect indicator — show offline state clearly when hub or WebSocket disconnects. `@sky`
- [x] Spawn delay feedback — immediate visual feedback (pulsing yellow dot) when clicking spawn. `@sky`
- [x] Word-level highlight — karaoke-style text highlighting synchronized with TTS playback. `@sky`
- [x] Keyboard shortcut — spacebar to start/stop recording, Option+1-7 to switch sessions. `@sky`
- [ ] Mobile improvements — optimized touch targets, haptic feedback, wake lock.

## iOS

- [ ] Live Activity revamp — auto mode gets full Dynamic Island with waveform, PTT mode gets compact with mic icon, typing mode uses push notifications.
- [ ] STT edit before send — show editable transcription after PTT recording before sending.
- [ ] Message editing — long-press sent message to edit, hub appends correction turn.
- [ ] Action Button integration — assign "Toggle Recording" to iPhone Action Button.
- [ ] Background mode improvements — proper audio session deactivation, background VAD tuning, background audio cues.
- [ ] Liquid Glass design — adopt Apple's Liquid Glass visual language for iOS 26.

## Branding

- [x] Rename to ClawMux — renamed from Voice Hub / Claude Team Mux. `@sky`

## Marketing

- [ ] Demo video — record and embed on the homepage.

## Documentation

- [x] AI-optimized docs — machine-readable `llms.txt` so LLMs can install autonomously. `@alloy`
- [x] API reference — all MCP tool signatures, WebSocket types, HTTP endpoints. `@sky`
- [ ] Troubleshooting guide — audio quality, latency, Tailscale, common failures.
