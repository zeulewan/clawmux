# Install

Open Claude Code and paste the prompt for your platform. Claude will handle everything.

## Install Prompt

First, choose your deployment mode. Then select your OS and copy the prompt.

=== "Together"

    Hub + TTS + STT all on the same machine. Requires a GPU.

    === "macOS"

        Requires Apple Silicon (M1+).

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        2. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        3. Install TTS/STT for Apple Silicon:
           pip install mlx-audio
           brew install whisper-cpp

        4. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        5. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        6. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

        Run each step, fix any errors, and report what happened.
        ```

    === "Linux"

        Requires NVIDIA GPU with CUDA.

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Install system dependencies (Debian/Ubuntu):
           sudo apt install -y python3-venv tmux

        2. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        3. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        4. Detect GPU and install TTS/STT:
           Run nvidia-smi. If NVIDIA GPU found:
           bash services/whisper/install.sh && bash services/whisper/start.sh && bash services/kokoro/install.sh && bash services/kokoro/start.sh
           If no GPU, stop and use the Split mode prompt instead.

        5. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        6. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        7. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

        Run each step, fix any errors, and report what happened.
        ```

    === "WSL"

        Requires NVIDIA GPU with WSL2 CUDA passthrough.

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Install system dependencies:
           sudo apt install -y python3-venv tmux

        2. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        3. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        4. Detect GPU and install TTS/STT:
           Run nvidia-smi. If NVIDIA GPU found:
           bash services/whisper/install.sh && bash services/whisper/start.sh && bash services/kokoro/install.sh && bash services/kokoro/start.sh
           If nvidia-smi not found, install CUDA for WSL: https://developer.nvidia.com/cuda/wsl

        5. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        6. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        7. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a Windows browser at http://localhost:3460.

        Run each step, fix any errors, and report what happened.
        ```

=== "Split"

    Hub runs locally, TTS/STT on a remote GPU server. No local GPU needed.

    === "macOS"

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        2. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        3. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        4. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        5. Configure Split mode — point TTS/STT at your remote GPU server:
           curl -X PUT http://localhost:3460/api/settings -H "Content-Type: application/json" -d '{"deployment_mode": "split", "tts_url": "http://YOUR_GPU_SERVER:8880", "stt_url": "http://YOUR_GPU_SERVER:2022"}'

        6. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

        Run each step, fix any errors, and report what happened.
        ```

    === "Linux"

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Install system dependencies (Debian/Ubuntu):
           sudo apt install -y python3-venv tmux

        2. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        3. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        4. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        5. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        6. Configure Split mode — point TTS/STT at your remote GPU server:
           curl -X PUT http://localhost:3460/api/settings -H "Content-Type: application/json" -d '{"deployment_mode": "split", "tts_url": "http://YOUR_GPU_SERVER:8880", "stt_url": "http://YOUR_GPU_SERVER:2022"}'

        7. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a browser.

        Run each step, fix any errors, and report what happened.
        ```

    === "WSL"

        ```
        Install ClawMux — an open-source voice interface for managing multiple Claude Code agents. The code is fully auditable on GitHub.

        1. Install system dependencies:
           sudo apt install -y python3-venv tmux

        2. Clone the repo:
           git clone https://github.com/zeulewan/clawmux.git ~/GIT/clawmux

        3. Set up Python:
           cd ~/GIT/clawmux && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt

        4. Review and install the CLI (review the script first — it's short):
           cat clawmux | head -20
           mkdir -p ~/.local/bin && cp clawmux ~/.local/bin/clawmux && chmod +x ~/.local/bin/clawmux
           Make sure ~/.local/bin is in your PATH.
           Or if you prefer system-wide: sudo cp clawmux /usr/local/bin/clawmux && sudo chmod +x /usr/local/bin/clawmux

        5. Start the hub:
           cd ~/GIT/clawmux && ./start-hub.sh

        6. Configure Split mode — point TTS/STT at your remote GPU server:
           curl -X PUT http://localhost:3460/api/settings -H "Content-Type: application/json" -d '{"deployment_mode": "split", "tts_url": "http://YOUR_GPU_SERVER:8880", "stt_url": "http://YOUR_GPU_SERVER:2022"}'

        7. Verify: curl -s http://localhost:3460/api/sessions and open http://localhost:3460 in a Windows browser at http://localhost:3460.

        Run each step, fix any errors, and report what happened.
        ```

## What Gets Installed

- Python venv with hub dependencies
- Whisper STT + Kokoro TTS (Together mode only)
- `clawmux` CLI for terminal control

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Linux / WSL / macOS |
| Python | 3.10+ |
| GPU | NVIDIA RTX 3070+ or Apple Silicon M1+ (Together mode) |
| RAM | 16GB+ |
| Claude Code | Installed and authenticated |

No GPU? Use **Split mode** — run the hub locally and point TTS/STT at a remote GPU server.

## After Install

Open in your browser: [http://localhost:3460](http://localhost:3460)

For remote access via Tailscale:

```bash
sudo tailscale serve --bg --https=3460 http://127.0.0.1:3460
```
