# Install ClawMux

Automated installation guide for AI agents. Select your platform and deployment mode, then run each section in order.

- **Together** — Hub + TTS + STT all on the same machine (requires GPU)
- **Split** — Hub runs locally, TTS/STT on a remote GPU server (no local GPU needed)

## 1. System Check

=== "macOS"

    ```bash
    # Verify Apple Silicon (required for Together mode)
    sysctl -n machdep.cpu.brand_string  # Must show "Apple M..."

    # Python
    python3 --version  # Must be 3.10+

    # Homebrew
    which brew || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # tmux
    which tmux || brew install tmux

    # Claude Code
    claude --version  # Must be installed and authenticated
    ```

=== "Linux"

    ```bash
    # OS
    uname -s  # Must be Linux

    # NVIDIA GPU (required for Together mode)
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null

    # Python
    python3 --version  # Must be 3.10+

    # tmux
    which tmux || sudo apt-get update && sudo apt-get install -y tmux

    # Claude Code
    claude --version  # Must be installed and authenticated
    ```

=== "WSL"

    ```bash
    # Verify WSL2
    cat /proc/version  # Should show "microsoft" or "WSL"

    # NVIDIA GPU passthrough (required for Together mode)
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null
    # If this fails: https://developer.nvidia.com/cuda/wsl

    # Python
    python3 --version  # Must be 3.10+

    # tmux
    which tmux || sudo apt-get update && sudo apt-get install -y tmux

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

=== "macOS Together"

    ```bash
    # Whisper STT via whisper.cpp
    brew install whisper-cpp

    WHISPER_MODELS="$HOME/.voicemode/services/whisper/models"
    mkdir -p "$WHISPER_MODELS"
    if [ ! -f "$WHISPER_MODELS/ggml-large-v3.bin" ]; then
        curl -L "https://huggingface.co/gguf-org/whisper-large-v3-GGUF/resolve/main/ggml-large-v3.bin" \
             -o "$WHISPER_MODELS/ggml-large-v3.bin"
    fi

    # Start Whisper server on port 2022
    if ! curl -s http://127.0.0.1:2022/v1/models > /dev/null 2>&1; then
        whisper-server \
            --model "$WHISPER_MODELS/ggml-large-v3.bin" \
            --port 2022 --host 127.0.0.1 &
        sleep 2
    fi

    # Kokoro TTS via mlx-audio
    pip install mlx-audio

    if ! curl -s http://127.0.0.1:8880/v1/models > /dev/null 2>&1; then
        mlx_audio serve --port 8880 --host 127.0.0.1 &
        sleep 3
    fi
    ```

=== "macOS Split"

    Skip local TTS/STT. Set up services on your GPU server:

    ```bash
    # On the GPU server:
    pip install voicemode
    voicemode whisper install && voicemode whisper start
    voicemode kokoro install && voicemode kokoro start
    ```

    Make services reachable from your Mac via Tailscale or SSH tunnel:

    ```bash
    # Option A: Tailscale (on GPU server)
    sudo tailscale serve --bg --https=8881 http://127.0.0.1:8880
    sudo tailscale serve --bg --https=2023 http://127.0.0.1:2022

    # Option B: SSH tunnel (on Mac)
    ssh -NL 8880:127.0.0.1:8880 -L 2022:127.0.0.1:2022 user@gpu-server &
    ```

=== "Linux Together"

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

=== "Linux Split"

    Skip local TTS/STT. Set up services on your GPU server:

    ```bash
    # On the GPU server:
    pip install voicemode
    voicemode whisper install && voicemode whisper start
    voicemode kokoro install && voicemode kokoro start
    ```

    Make services reachable via Tailscale or SSH tunnel:

    ```bash
    # Option A: Tailscale (on GPU server)
    sudo tailscale serve --bg --https=8881 http://127.0.0.1:8880
    sudo tailscale serve --bg --https=2023 http://127.0.0.1:2022

    # Option B: SSH tunnel (on local machine)
    ssh -NL 8880:127.0.0.1:8880 -L 2022:127.0.0.1:2022 user@gpu-server &
    ```

=== "WSL Together"

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

=== "WSL Split"

    Skip local TTS/STT. Set up services on your GPU server:

    ```bash
    # On the GPU server:
    pip install voicemode
    voicemode whisper install && voicemode whisper start
    voicemode kokoro install && voicemode kokoro start
    ```

    Make services reachable from WSL via Tailscale or SSH tunnel:

    ```bash
    # In WSL — install Tailscale first
    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up

    # Option A: Tailscale (on GPU server)
    sudo tailscale serve --bg --https=8881 http://127.0.0.1:8880
    sudo tailscale serve --bg --https=2023 http://127.0.0.1:2022

    # Option B: SSH tunnel (in WSL)
    ssh -NL 8880:127.0.0.1:8880 -L 2022:127.0.0.1:2022 user@gpu-server &
    ```

## 5. Configure Split Mode

!!! note "Split mode only"
    Skip this section if you chose a **Together** setup.

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

Or in tmux (persists after terminal closes):
```bash
tmux new-session -d -s clawmux "cd $HOME/GIT/clawmux && ./start-hub.sh"
```

## 10. Access the UI

=== "macOS / Linux"

    Open `http://localhost:3460` in your browser.

=== "WSL"

    Open `http://localhost:3460` in your **Windows** browser.
    WSL2 forwards localhost ports automatically. If it doesn't work:

    ```bash
    WSL_IP=$(hostname -I | awk '{print $1}')
    echo "Try http://$WSL_IP:3460"
    ```

## 11. Tailscale HTTPS (Optional)

For remote access from phone/tablet/other machines:
```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```

Access at `https://<hostname>.ts.net:3460`.

## 12. Verify

```bash
# Hub running
curl -s http://localhost:3460/api/sessions | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'sessions')"

# TTS working
curl -s http://127.0.0.1:8880/v1/models | head -c 100

# STT working
curl -s http://127.0.0.1:2022/v1/models | head -c 100
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
| Port 3460 in use | Check what is using it: `lsof -i:3460` |
| TTS/STT connection refused | Check services: `voicemode whisper status` / `voicemode kokoro status` |
| No GPU detected | Use split mode with a remote GPU server |
| mlx-audio fails | Requires Apple Silicon — does not work on Intel Macs |
| nvidia-smi not found in WSL | Install CUDA drivers for WSL: [nvidia.com/cuda/wsl](https://developer.nvidia.com/cuda/wsl) |
| WSL port not accessible | Try WSL IP directly: `hostname -I` |
| SSH tunnel dies | Use `autossh` for persistent tunnels |
| Permission denied on CLI | Use `sudo` or add cli directory to PATH |
