# Install ClawMux — Linux Together

Everything runs locally on a Linux machine with an NVIDIA GPU. Hub + TTS (Kokoro) + STT (Whisper) all on the same box.

**Requirements:** Linux (Ubuntu 20.04+/Debian 11+), NVIDIA GPU with CUDA, Python 3.10+, Claude Code

## 1. System Check

```bash
# OS
uname -s  # Must be Linux

# NVIDIA GPU
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# Python
python3 --version  # Must be 3.10+

# System dependencies (Debian/Ubuntu)
sudo apt install -y python3-venv tmux

# Claude Code
claude --version  # Must be installed and authenticated
```

## 2. Clone Repository

```bash
if [ ! -d "$HOME/GIT/clawmux" ]; then
    mkdir -p "$HOME/GIT"
    git clone https://github.com/zeulewan/clawmux.git "$HOME/GIT/clawmux"
fi
cd "$HOME/GIT/clawmux"
```

## 3. Python Environment

```bash
cd "$HOME/GIT/clawmux"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 4. TTS and STT Services (VoiceMode)

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

## 5. Register MCP Server

```bash
INSTALL_DIR="$HOME/GIT/clawmux"
claude mcp add -s user clawmux -- "$INSTALL_DIR/.venv/bin/python" "$INSTALL_DIR/server/mcp_server.py"
```

## 6. Install Slash Commands

```bash
mkdir -p ~/.claude/commands
cp "$HOME/GIT/clawmux/.claude/commands/clawmux.md" ~/.claude/commands/clawmux.md
```

## 7. Install CLI

```bash
# Review the script first
cat "$HOME/GIT/clawmux/clawmux" | head -20

# Option A: User-local install (no sudo needed)
mkdir -p ~/.local/bin
cp "$HOME/GIT/clawmux/clawmux" ~/.local/bin/clawmux
chmod +x ~/.local/bin/clawmux
# Ensure ~/.local/bin is in your PATH

# Option B: System-wide install
sudo cp "$HOME/GIT/clawmux/clawmux" /usr/local/bin/clawmux
sudo chmod +x /usr/local/bin/clawmux
```

## 8. Start the Hub

```bash
cd "$HOME/GIT/clawmux"
./start-hub.sh
```

Or in tmux (persists after terminal closes):
```bash
tmux new-session -d -s clawmux "cd $HOME/GIT/clawmux && ./start-hub.sh"
```

## 9. Tailscale HTTPS (Optional)

For remote access from phone/tablet/other machines:
```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Access at `https://<hostname>.ts.net:3460`.

## 10. Verify

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

## Troubleshooting

| Problem | Fix |
|---------|-----|
| CUDA not found | Install NVIDIA drivers and CUDA toolkit: `sudo apt install nvidia-driver-535 nvidia-cuda-toolkit` |
| Whisper OOM | Use a smaller model: `voicemode whisper config --model base` |
| Port 3460 in use | Check what is using it: `lsof -i:3460` |
| TTS/STT connection refused | Check services: `voicemode whisper status` / `voicemode kokoro status` |
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
| Permission denied on CLI install | Run `sudo cp` or add the cli directory to your PATH |
