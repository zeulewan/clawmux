# Install

Open Claude Code and paste the prompt for your platform. Claude will handle everything.

## Linux / WSL

Copy and paste this into Claude Code:

```
Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

1. Clone the repo:
   git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

2. Set up Python:
   cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

3. Detect GPU:
   Run nvidia-smi. If NVIDIA GPU found, install TTS/STT:
   pip install voicemode && voicemode whisper install && voicemode whisper start && voicemode kokoro install && voicemode kokoro start
   If no GPU, skip this — I'll use Split mode with a remote GPU server later.

4. Install the CLI:
   sudo cp cli/clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

5. Register MCP server:
   claude mcp add -s user clawmux -- ~/GIT/clawmux/.venv/bin/python ~/GIT/clawmux/server/mcp_server.py

6. Install slash commands:
   mkdir -p ~/.claude/commands && cp ~/GIT/clawmux/.claude/commands/clawmux.md ~/.claude/commands/clawmux.md

7. Start the hub:
   cd ~/GIT/clawmux && ./start-hub.sh

8. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

Run each step, fix any errors, and report what happened.
```

## Mac (Apple Silicon)

Copy and paste this into Claude Code:

```
Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

1. Clone the repo:
   git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

2. Set up Python:
   cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

3. Install TTS/STT for Apple Silicon:
   pip install mlx-audio
   Note: Whisper via whisper.cpp and Kokoro via mlx-audio are still being integrated.
   For now, use Split mode — point TTS/STT at a remote GPU server after setup.

4. Install the CLI:
   sudo cp cli/clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

5. Register MCP server:
   claude mcp add -s user clawmux -- ~/GIT/clawmux/.venv/bin/python ~/GIT/clawmux/server/mcp_server.py

6. Install slash commands:
   mkdir -p ~/.claude/commands && cp ~/GIT/clawmux/.claude/commands/clawmux.md ~/.claude/commands/clawmux.md

7. Start the hub:
   cd ~/GIT/clawmux && ./start-hub.sh

8. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

9. If using Split mode (remote GPU for TTS/STT), configure after hub starts:
   curl -X PUT http://localhost:3460/api/settings -H "Content-Type: application/json" -d '{"deployment_mode": "split", "tts_url": "http://YOUR_GPU_SERVER:8880", "stt_url": "http://YOUR_GPU_SERVER:2022"}'

Run each step, fix any errors, and report what happened.
```

## What Gets Installed

- Python venv with hub dependencies
- Whisper STT + Kokoro TTS (if GPU available)
- `clawmux` CLI for terminal control
- MCP server registered with Claude Code
- Slash commands for quick voice mode access

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Linux / WSL / macOS |
| Python | 3.10+ |
| GPU | NVIDIA RTX 3070+ or Apple Silicon M3 Pro+ |
| RAM | 16GB+ |
| Claude Code | Installed and authenticated |

No GPU? Use **Split mode** — run the hub locally and point TTS/STT at a remote GPU server.

## After Install

Open in your browser: [http://localhost:3460](http://localhost:3460)

For remote access via Tailscale:

```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```
