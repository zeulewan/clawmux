# Install

Open Claude Code and paste this prompt. Claude will handle everything.

## Install Prompt

```
Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub. Review the install script before running it.

1. Clone the repo:
   git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

2. Review the install script (it's short — read it to see what it does):
   cat ~/GIT/clawmux/install.sh

3. Run the installer:
   cd ~/GIT/clawmux && ./install.sh

4. If no local GPU was detected, configure remote TTS/STT in Settings (http://localhost:3460) or via:
   curl -X PUT http://localhost:3460/api/settings -H "Content-Type: application/json" -d '{"tts_url": "http://YOUR_GPU_SERVER:8880", "stt_url": "http://YOUR_GPU_SERVER:2022"}'

5. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

Run each step, fix any errors, and report what happened.
```

## What Gets Installed

The install script detects your OS and GPU, then handles everything:

- System dependencies (tmux, brew on macOS)
- Python venv with hub dependencies
- Whisper STT + Kokoro TTS (if GPU detected)
- `clawmux` CLI
- Claude Code hooks and slash commands

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Linux / WSL / macOS |
| Python | 3.10+ |
| GPU | NVIDIA RTX 3070+ or Apple Silicon M1+ (for local TTS/STT) |
| RAM | 16GB+ |
| Claude Code | Installed and authenticated |

No GPU? The installer will detect that and skip TTS/STT setup. Just point at a remote GPU server in Settings afterwards.

## After Install

Open in your browser: [http://localhost:3460](http://localhost:3460)

For remote access via Tailscale:

```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```
