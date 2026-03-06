# Install ClawMux — macOS Split

Hub runs locally on Mac. TTS and STT run on a remote GPU server (Linux with NVIDIA GPU).

**Requirements:** macOS 12+, Python 3.10+, Claude Code, remote Linux server with NVIDIA GPU accessible via network

## 1. System Check (Mac)

```bash
# Python
python3 --version  # Must be 3.10+

# tmux
which tmux || brew install tmux

# Claude Code
claude --version  # Must be installed and authenticated
```

## 2. Clone Repository (Mac)

```bash
if [ ! -d "$HOME/GIT/clawmux" ]; then
    mkdir -p "$HOME/GIT"
    git clone https://github.com/zeulewan/clawmux.git "$HOME/GIT/clawmux"
fi
cd "$HOME/GIT/clawmux"
```

## 3. Python Environment (Mac)

```bash
cd "$HOME/GIT/clawmux"
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## 4. GPU Server Setup

SSH into your GPU server and set up TTS/STT:

```bash
# On the GPU server:
pip install voicemode

# Whisper STT (port 2022)
voicemode whisper install
voicemode whisper start

# Kokoro TTS (port 8880)
voicemode kokoro install
voicemode kokoro start
```

Make the services accessible from your Mac. Options:

- **Tailscale** (recommended): Both machines on the same tailnet. Use Tailscale IPs.
  ```bash
  # On GPU server — expose via Tailscale serve
  sudo tailscale serve --bg --https=8881 http://127.0.0.1:8880
  sudo tailscale serve --bg --https=2023 http://127.0.0.1:2022
  ```
- **SSH tunnel**: Forward ports from Mac to GPU server.
  ```bash
  # On Mac — tunnel TTS and STT
  ssh -NL 8880:127.0.0.1:8880 -L 2022:127.0.0.1:2022 user@gpu-server &
  ```

## 5. Configure Split Mode (Mac)

After the hub starts, configure remote TTS/STT URLs:

```bash
# Replace GPU_SERVER with the Tailscale IP or hostname of your GPU server
GPU_SERVER="100.x.x.x"  # Or hostname.ts.net

curl -X PUT http://localhost:3460/api/settings \
  -H "Content-Type: application/json" \
  -d "{\"deployment_mode\": \"split\", \"tts_url\": \"http://${GPU_SERVER}:8880\", \"stt_url\": \"http://${GPU_SERVER}:2022\"}"
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
sudo cp "$HOME/GIT/clawmux/cli/clawmux" /usr/local/bin/clawmux
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

## 10. Tailscale HTTPS (Optional)

For remote access from phone/tablet:
```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
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
echo "Open http://localhost:3460 in your browser"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| TTS/STT connection refused | Check GPU server services: `voicemode whisper status` / `voicemode kokoro status` |
| Tailscale not connecting | Ensure both machines are on the same tailnet: `tailscale status` |
| SSH tunnel dies | Use `autossh` for persistent tunnels: `brew install autossh` |
| High latency | Tailscale direct connection preferred over relayed. Check `tailscale ping gpu-server` |
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
