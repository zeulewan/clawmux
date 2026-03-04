# Getting Started

## Prerequisites

You need:

- **Claude Code** — installed and authenticated
- **NVIDIA GPU** with at least 4 GB VRAM (for Whisper STT and Kokoro TTS)
- **Tailscale** — if you want to access from your phone or another machine

That's it. Your agent handles the actual installation.

## Install

Ask your Claude Code agent:

> "Install ClawMux. Read the agent reference at `zensical/agents/reference/agent-reference.md` and set everything up."

Claude will check your system, install dependencies, clone the repo, register the MCP server, and set up Tailscale if needed.

## Starting and Stopping the Hub

Start:

```bash
cd ~/GIT/clawmux
./start-hub.sh
```

Or in tmux (keeps running after your terminal closes):

```bash
tmux new-session -d -s clawmux 'cd ~/GIT/clawmux && ./start-hub.sh'
```

Stop:

```bash
tmux kill-session -t clawmux
```

Or kill directly:

```bash
pkill -f hub.py
```

!!! warning "Use `start-hub.sh`, not `python hub.py` directly"
    Running `hub.py` directly skips the cleanup step and orphaned processes will accumulate over time.

## Troubleshooting

**MCP tools not found:** Wait 10 seconds after starting Claude Code for the MCP server to initialize, then try again.

**502 Bad Gateway in browser:** The hub hasn't started yet. Check `tail -f /tmp/clawmux.log`.

**Port 3460 in use:** Run `pkill -f hub.py` to clear any stale processes, then restart.
