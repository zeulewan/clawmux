# Install ClawMux — WSL Split

Hub runs in WSL (Windows Subsystem for Linux). TTS and STT run on a remote GPU server.

**Requirements:** Windows 10/11, WSL2 with Ubuntu, Python 3.10+, Claude Code, remote Linux server with NVIDIA GPU accessible via network

## 1. WSL Check

```bash
# Verify WSL2
cat /proc/version  # Should show "microsoft" or "WSL"

# Python
python3 --version  # Must be 3.10+

# System dependencies
sudo apt install -y python3-venv tmux

# Claude Code
claude --version  # Must be installed and authenticated
```

No local GPU is required — TTS/STT run on the remote server.

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

## 4. GPU Server Setup

SSH into your GPU server, clone the repo, and set up TTS/STT:

```bash
# On the GPU server:
git clone https://github.com/zeulewan/clawmux.git ~/clawmux
cd ~/clawmux

# Install Whisper and Kokoro services
bash services/whisper/install.sh
bash services/whisper/start.sh

bash services/kokoro/install.sh
bash services/kokoro/start.sh
```

Environment variables (optional — shown with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAWMUX_HOME` | `~/.clawmux` | Base directory |
| `CLAWMUX_WHISPER_PORT` | `2022` | Whisper STT port |
| `CLAWMUX_KOKORO_PORT` | `8880` | Kokoro TTS port |
| `CLAWMUX_WHISPER_MODEL` | `large-v3` | Whisper model size |

Make the services accessible from WSL. Options:

- **Tailscale** (recommended): Both WSL and GPU server on the same tailnet.
  ```bash
  # In WSL — install Tailscale
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up

  # On GPU server — expose via Tailscale serve
  sudo tailscale serve --bg --https=8881 http://127.0.0.1:8880
  sudo tailscale serve --bg --https=2023 http://127.0.0.1:2022
  ```
- **SSH tunnel**: Forward ports from WSL to GPU server.
  ```bash
  # In WSL — tunnel TTS and STT
  ssh -NL 8880:127.0.0.1:8880 -L 2022:127.0.0.1:2022 user@gpu-server &
  ```

## 5. Configure Remote TTS/STT

After the hub starts, configure remote TTS/STT URLs:

```bash
# Replace GPU_SERVER with the Tailscale IP or hostname of your GPU server
GPU_SERVER="100.x.x.x"  # Or hostname.ts.net

curl -X PUT http://localhost:3460/api/settings \
  -H "Content-Type: application/json" \
  -d "{\"tts_url\": \"http://${GPU_SERVER}:8880\", \"stt_url\": \"http://${GPU_SERVER}:2022\"}"
```

If using SSH tunnels, the URLs are `http://127.0.0.1:8880` and `http://127.0.0.1:2022`.

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

Or in tmux:
```bash
tmux new-session -d -s clawmux "cd $HOME/GIT/clawmux && ./start-hub.sh"
```

## 10. Access from Windows

Open a browser on Windows and go to `http://localhost:3460`.

WSL2 automatically forwards localhost ports to Windows. If this doesn't work:
```bash
WSL_IP=$(hostname -I | awk '{print $1}')
echo "Try http://$WSL_IP:3460 from Windows"
```

## 11. Verify

```bash
# Hub running
curl -s http://localhost:3460/api/sessions | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'sessions')"

# TTS working (via configured URL)
curl -s http://${GPU_SERVER}:8880/v1/models | head -c 100

# STT working (via configured URL)
curl -s http://${GPU_SERVER}:2022/v1/models | head -c 100

# Browser UI
echo "Open http://localhost:3460 in your Windows browser"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| TTS/STT connection refused | Check GPU server services: `curl -s http://127.0.0.1:2022/v1/models` / `curl -s http://127.0.0.1:8880/v1/models` |
| Tailscale in WSL issues | Ensure WSL2 (not WSL1): `wsl --set-version Ubuntu 2` |
| Port not accessible from Windows | Try WSL IP directly instead of localhost |
| SSH tunnel dies | Use `autossh`: `sudo apt install autossh` |
| WSL restarts lose services | Add startup commands to `~/.bashrc` |
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
