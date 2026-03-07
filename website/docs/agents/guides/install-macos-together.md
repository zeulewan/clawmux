# Install ClawMux — macOS Together

Everything runs locally on Apple Silicon. Hub + TTS (mlx-audio/Kokoro) + STT (whisper.cpp) on the same Mac.

**Requirements:** Apple Silicon Mac (M1+), macOS 14+, Python 3.10+, Homebrew, Claude Code

## 1. System Check

```bash
# Verify Apple Silicon
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

## 4. Whisper STT (whisper.cpp)

```bash
# Install whisper.cpp via Homebrew
brew install whisper-cpp

# Download the large-v3 model for best accuracy
WHISPER_MODELS="$HOME/.clawmux/services/whisper/models"
mkdir -p "$WHISPER_MODELS"
if [ ! -f "$WHISPER_MODELS/ggml-large-v3.bin" ]; then
    curl -L "https://huggingface.co/gguf-org/whisper-large-v3-GGUF/resolve/main/ggml-large-v3.bin" \
         -o "$WHISPER_MODELS/ggml-large-v3.bin"
fi

# Start Whisper server on port 2022
if ! curl -s http://127.0.0.1:2022/v1/models > /dev/null 2>&1; then
    whisper-server \
        --model "$WHISPER_MODELS/ggml-large-v3.bin" \
        --port 2022 \
        --host 127.0.0.1 &
    sleep 2
fi
```

## 5. Kokoro TTS (mlx-audio)

```bash
# Install mlx-audio for Apple Silicon optimized TTS
pip install mlx-audio

# Start Kokoro TTS on port 8880
if ! curl -s http://127.0.0.1:8880/v1/models > /dev/null 2>&1; then
    mlx_audio serve --port 8880 --host 127.0.0.1 &
    sleep 3
fi
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

## Troubleshooting

| Problem | Fix |
|---------|-----|
| mlx-audio fails | Ensure Apple Silicon — mlx does not work on Intel Macs |
| whisper-cpp slow | Use a smaller model: `ggml-base.bin` for faster but less accurate transcription |
| Port conflict | Kill existing processes: check `lsof -i:3460` / `lsof -i:8880` / `lsof -i:2022` |
| MCP tools not found | Wait 10s after starting Claude Code, then retry |
