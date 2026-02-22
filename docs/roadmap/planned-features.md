# Planned Features

Items not yet assigned to a release.

### Zero-Touch Experience

- [ ] **One-command setup** — Single script that installs all dependencies, builds Whisper with CUDA, sets up Kokoro, creates the Python venv, registers the MCP server, and configures Tailscale.

### Installation & Packaging

- [ ] **Standalone install scripts** — Remove the VoiceMode dependency by installing [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and [kokoro-fastapi](https://github.com/remsky/kokoro-fastapi) directly from their upstream repos with bundled install scripts and systemd service files.
- [ ] **Health check endpoint** — `/health` endpoint on the MCP server that verifies Whisper, Kokoro, and WebSocket connectivity in one call.

### Reliability

- [ ] **Service health monitoring** — Detect when Whisper or Kokoro services go down and show a clear error in the browser UI instead of a generic failure.

### Audio & Voice

- [ ] **Voice selection in UI** — Let users pick from available Kokoro voices directly in the browser interface with a dropdown or buttons.
- [ ] **Adjustable speech speed** — Control TTS playback speed from the browser UI.
- [ ] **Whisper model selection** — Choose between Whisper model sizes (tiny, base, small, medium, large) from the UI for quality vs. speed tradeoff.
- [ ] **Voice interruption** — Detect when the user starts speaking during TTS playback and automatically stop the audio, allowing the user to interrupt Claude mid-sentence.

### Browser UI

- [ ] **Settings panel** — In-browser controls for voice, speed, Whisper model, and other configuration without editing files.
- [ ] **Keyboard shortcut** — Press-and-hold spacebar to record, release to send (desktop browsers).
- [ ] **Mobile improvements** — Optimized touch targets, haptic feedback on recording start/stop, and wake lock to prevent screen sleep during conversations.
- [ ] **Dark/light theme** — Match system preference or allow manual toggle.

### Multi-Agent

- [ ] **Shared hub** — A persistent WebSocket hub process that all MCP server instances register with. The browser connects to the hub and sees each agent as a tab. When an agent calls `converse()`, the hub buffers the TTS audio and shows a notification badge. Audio only plays when the user selects that tab. The `converse()` call blocks until the user listens and responds.

### Documentation

- [ ] **Demo video** — Record and embed a demo video on the homepage showing a voice conversation in action.
- [ ] **AI-optimized documentation** — Provide a machine-readable version of the docs (e.g. `llms.txt` or structured context file) alongside the human-readable site, so LLMs can install and configure voice-hub autonomously.
- [ ] **API reference** — Document all MCP tool signatures, WebSocket message types, and HTTP endpoints.
- [ ] **Troubleshooting guide** — Expanded guide covering audio quality issues, latency, Tailscale connectivity, and common failure modes.
