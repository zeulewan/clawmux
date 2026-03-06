# Install ClawMux

Automated installation guide for AI agents. Run each section in order. Skip sections where checks pass.

## 1. System Check

```bash
# OS
uname -s  # Must be Linux or Darwin

# Python
python3 --version  # Must be 3.10+

# tmux
which tmux || (sudo apt-get update && sudo apt-get install -y tmux)

# Claude Code
claude --version  # Must be installed and authenticated
```

## 2. GPU Detection

```bash
# NVIDIA GPU
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null

# Apple Silicon
sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -i apple
```

Based on the result, set the deployment mode:
- **NVIDIA GPU detected**: Mode = `local` (everything on this machine)
- **Apple Silicon detected**: Mode = `local` (use mlx-audio + whisper.cpp)
- **No GPU**: Mode = `split` (TTS/STT on a remote GPU server)

## 3. Clone Repository

```bash
# Clone if not already present
if [ ! -d "$HOME/GIT/clawmux" ]; then
    mkdir -p "$HOME/GIT"
    git clone https://github.com/zeulewan/clawmux.git "$HOME/GIT/clawmux"
fi
cd "$HOME/GIT/clawmux"
```

## 4. Python Environment

```bash
cd "$HOME/GIT/clawmux"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 5. TTS and STT Services

### NVIDIA GPU

```bash
# Install VoiceMode (manages Whisper + Kokoro services)
pip install voicemode

# Whisper STT (port 2022)
if ! curl -s http://127.0.0.1:2022/v1/models > /dev/null 2>&1; then
    voicemode whisper install
    voicemode whisper start
fi

# Kokoro TTS (port 8880)
if ! curl -s http://127.0.0.1:8880/v1/models > /dev/null 2>&1; then
    voicemode kokoro install
    voicemode kokoro start
fi
```

### Apple Silicon

```bash
# mlx-audio for TTS
pip install mlx-audio
# Start Kokoro via mlx-audio on port 8880
# (implementation pending)

# whisper.cpp for STT
# brew install whisper-cpp
# (implementation pending)
```

### No GPU (Split Mode)

Skip TTS/STT installation. Configure remote URLs after setup:
```bash
# Set remote TTS/STT URLs via the settings API after hub starts
curl -X PUT http://localhost:3460/api/settings \
  -H "Content-Type: application/json" \
  -d '{"deployment_mode": "split", "tts_url": "http://GPU_SERVER:8880", "stt_url": "http://GPU_SERVER:2022"}'
```

## 6. Register MCP Server

```bash
INSTALL_DIR="$HOME/GIT/clawmux"
claude mcp add -s user clawmux -- "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/server/mcp_server.py"
```

## 7. Install Slash Commands

```bash
mkdir -p ~/.claude/commands
cp "$HOME/GIT/clawmux/.claude/commands/clawmux.md" ~/.claude/commands/clawmux.md
```

## 8. Install CLI

```bash
sudo cp "$HOME/GIT/clawmux/cli/clawmux" /usr/local/bin/clawmux
sudo chmod +x /usr/local/bin/clawmux
```

## 9. Start the Hub

```bash
cd "$HOME/GIT/clawmux"
./start-hub.sh
```

Or in tmux (persists after terminal closes):
```bash
tmux new-session -d -s clawmux "cd $HOME/GIT/clawmux && ./start-hub.sh"
```

## 10. Tailscale HTTPS (Optional)

For remote access from phone/tablet/other machines:
```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Access at `https://<hostname>.ts.net:3460`.

## 11. Verify

```bash
# Hub running
curl -s http://localhost:3460/api/sessions | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'sessions')"

# TTS working
curl -s http://127.0.0.1:8880/v1/models | head -c 100

# STT working
curl -s http://127.0.0.1:2022/v1/models | head -c 100

# Browser UI
echo "Open http://localhost:3460 in your browser"
```

## Uninstall

```bash
# Stop hub
pkill -f hub.py

# Remove MCP server
claude mcp remove clawmux

# Remove slash commands
rm ~/.claude/commands/clawmux.md

# Remove CLI
sudo rm /usr/local/bin/clawmux

# Remove repo (optional)
rm -rf "$HOME/GIT/clawmux"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
| Port 3460 in use | `pkill -f hub.py` then restart |
| TTS/STT connection refused | Check services: `voicemode whisper status` / `voicemode kokoro status` |
| No GPU detected | Use split mode with a remote GPU server |
| Permission denied on CLI install | Run `sudo cp` or add the cli directory to your PATH |
