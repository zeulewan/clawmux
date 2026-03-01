# Getting Started

## Hardware Requirements

| Component | VRAM | RAM | Notes |
|-----------|------|-----|-------|
| Whisper STT | ~640 MB | ~360 MB | whisper.cpp with CUDA, `base` model |
| Kokoro TTS | ~2 GB | ~3 GB | kokoro-fastapi with GPU inference |
| **Total** | **~3 GB** | **~3.5 GB** | |

An NVIDIA GPU with at least 4 GB of VRAM is required. Tested on RTX 3090.

## Prerequisites

!!! info "Required services"

    Voice Hub relies on two local services that must be running:

    - **Whisper STT** — GPU-accelerated speech-to-text ([whisper.cpp](https://github.com/ggerganov/whisper.cpp), port 2022)
    - **Kokoro TTS** — GPU-accelerated text-to-speech ([kokoro-fastapi](https://github.com/remsky/kokoro-fastapi), port 8880)

    These are managed by [VoiceMode](https://github.com/mbailey/voicemode):

    ```bash
    uvx voice-mode-install --yes
    voicemode whisper install
    voicemode kokoro install
    ```

You also need:

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (CLI)
- Python 3.10+
- NVIDIA GPU with CUDA support
- [Tailscale](https://tailscale.com/) (for remote access from other devices)

## Install

```bash
git clone https://github.com/zeulewan/voice-hub.git
cd voice-hub
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Register MCP Server

```bash
claude mcp add -s user voice-hub -- /path/to/voice-hub/.venv/bin/python /path/to/voice-hub/mcp_server.py
```

Replace `/path/to/voice-hub` with the actual path to the cloned repo. Verify with:

```bash
claude mcp list
```

## Install Slash Command and Skill

Copy the Claude Code command and skill files from the repo:

```bash
cp .claude/commands/voice-hub.md ~/.claude/commands/voice-hub.md
mkdir -p ~/.claude/skills/voice-hub
cp .claude/skills/voice-hub/skill.md ~/.claude/skills/voice-hub/skill.md
```

This registers the `/voice-hub` command and teaches Claude how to use the voice tools.

## Remote Access via Tailscale

Expose the server over HTTPS on your tailnet:

```bash
sudo tailscale serve --bg --https=3456 http://127.0.0.1:3456
```

Then open `https://<your-machine>.ts.net:3456` from any device on your tailnet.

## Usage

1. Start Claude Code — the MCP server launches automatically
2. Open the web UI in your browser (green dot = connected)
3. Run `/voice-hub` in Claude Code
4. Claude greets you — speak your request when prompted
5. Claude processes your request using its full tool set, then speaks the response
6. Continue the conversation until you say goodbye

## Managing the Hub

Use the included script to start the hub — it kills any existing instances first to prevent duplicates:

```bash
cd ~/GIT/voice-chat
./start-hub.sh
```

To keep it running after your terminal closes, use tmux:

```bash
tmux new-session -d -s voice-hub 'cd ~/GIT/voice-chat && ./start-hub.sh'
```

Stop it:

```bash
tmux kill-session -t voice-hub
```

Or kill the process directly:

```bash
pkill -f hub.py
```

!!! warning "Don't use `python hub.py` directly"

    Running `.venv/bin/python hub.py` directly will spawn a new instance without stopping any existing ones. Over time this causes orphaned processes to accumulate (one per session). Always use `./start-hub.sh` instead.

## Troubleshooting

**MCP tools not found:** Wait 10 seconds after starting Claude Code for the MCP server to initialize, then try again.

**502 Bad Gateway in browser:** The WebSocket server hasn't started yet. Check `tail -f /tmp/voice-hub-mcp.log` for status.

**Port 3456 in use:** The server retries every 5 seconds. Kill any stale processes: `lsof -i:3456` then `kill <pid>`.
