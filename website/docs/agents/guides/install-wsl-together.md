# Install ClawMux — WSL Together

Everything runs in WSL (Windows Subsystem for Linux) with NVIDIA GPU passthrough. Hub + TTS (Kokoro) + STT (Whisper) all in WSL.

**Requirements:** Windows 11, WSL2 with Ubuntu, NVIDIA GPU with CUDA support in WSL, Python 3.10+, Claude Code

## 1. WSL and GPU Check

```bash
# Verify WSL2
cat /proc/version  # Should show "microsoft" or "WSL"

# NVIDIA GPU passthrough
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
# If this fails, install NVIDIA CUDA drivers for WSL:
# https://developer.nvidia.com/cuda/wsl

# Python
python3 --version  # Must be 3.10+

# System dependencies
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

## 4. TTS and STT Services

Environment variables (optional — shown with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWMUX_HOME` | `~/.clawmux` | Base directory |
| `CLAWMUX_WHISPER_PORT` | `2022` | Whisper STT port |
| `CLAWMUX_KOKORO_PORT` | `8880` | Kokoro TTS port |
| `CLAWMUX_WHISPER_MODEL` | `large-v3` | Whisper model size |

```bash
cd "$HOME/GIT/clawmux"

# Install Whisper and Kokoro services
# Whisper STT (port 2022)
if ! curl -s http://127.0.0.1:2022/v1/models > /dev/null 2>&1; then
    bash services/whisper/install.sh
    bash services/whisper/start.sh
fi

# Kokoro TTS (port 8880)
if ! curl -s http://127.0.0.1:8880/v1/models > /dev/null 2>&1; then
    bash services/kokoro/install.sh
    bash services/kokoro/start.sh
fi
```

## 5. Audio Setup (WSL)

WSL does not natively support audio. The browser handles recording and playback — no WSL audio setup needed. The hub serves audio via WebSocket to the browser.

To access the hub from Windows, WSL forwards `localhost` ports automatically:
```bash
# Test from Windows browser: http://localhost:3460
# If port forwarding doesn't work, find WSL IP:
hostname -I | awk '{print $1}'
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

## 9. Start the Hub

```bash
cd "$HOME/GIT/clawmux"
./start-hub.sh
```

Or in tmux (persists after terminal closes):
```bash
tmux new-session -d -s clawmux "cd $HOME/GIT/clawmux && ./start-hub.sh"
```

## 10. Access from Windows

Open a browser on Windows and go to `http://localhost:3460`.

For access from other devices on your network:
```bash
# Find WSL IP
WSL_IP=$(hostname -I | awk '{print $1}')
echo "Access at http://$WSL_IP:3460"
```

## 11. Tailscale (Optional)

For remote access, install Tailscale in WSL:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

## 12. Verify

```bash
# Hub running
curl -s http://localhost:3460/api/sessions | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'sessions')"

# TTS working
curl -s http://127.0.0.1:8880/v1/models | head -c 100

# STT working
curl -s http://127.0.0.1:2022/v1/models | head -c 100

# Browser UI
echo "Open http://localhost:3460 in your Windows browser"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| nvidia-smi not found | Install NVIDIA CUDA drivers for WSL from [nvidia.com/cuda/wsl](https://developer.nvidia.com/cuda/wsl) |
| Port not accessible from Windows | Check WSL networking: `wsl --version` (must be WSL2). Try WSL IP directly. |
| Services crash on GPU OOM | Use a smaller Whisper model: set `CLAWMUX_WHISPER_MODEL=base` and re-run `bash services/whisper/install.sh` |
| WSL restarts lose services | Add startup commands to `~/.bashrc` or use a systemd service |
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
