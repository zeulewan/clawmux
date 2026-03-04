# Deployment Modes Brief

*Created: 2026-03-03 8:45 PM EST*

How ClawMux will run on different devices and network configurations.

## The Problem

ClawMux currently runs on a single workstation (RTX 3090, Linux) with everything co-located: the hub, agents, TTS (Kokoro), and STT (Whisper). To make ClawMux a public app that works on any device, we need flexible deployment modes that adapt to what hardware and network the user has.

## Three Deployment Modes

### Mode 1: Thin Client (Terminal Mode)

The user's device (phone, tablet, laptop) acts purely as a terminal. Everything runs on a remote server.

```
┌──────────────┐         ┌────────────────────────────┐
│  Phone/iPad  │◄───────►│     Remote Server           │
│  (browser)   │  HTTPS  │  Hub + Agents + TTS + STT  │
│  audio only  │         │  (GPU required)             │
└──────────────┘         └────────────────────────────┘
```

- Device does nothing except stream audio and display the UI
- All compute on the server
- Best for: phones, low-power devices, using ClawMux on the go
- Requires: network connection to server

### Mode 2: Split Architecture (Recommended)

Hub and agents run locally. TTS and STT run on a remote GPU server.

```
┌─────────────────────────────┐      ┌──────────────────┐
│     Local Machine            │      │   GPU Server      │
│  Hub + Agents (Claude Code)  │◄────►│  Kokoro TTS       │
│  Browser UI                  │ HTTP │  Whisper STT      │
│  No GPU needed               │      │  (RTX 3070+)      │
└─────────────────────────────┘      └──────────────────┘
```

- Hub runs on Mac/Linux/Windows, agents run locally
- TTS/STT calls go to remote server over Tailscale or HTTPS
- Just change `WHISPER_URL` and `KOKORO_URL` in config
- Best for: users with a Mac and a separate GPU machine
- Requires: network connection to GPU server

### Mode 3: Fully Local

Everything runs on the user's machine. No network dependency.

```
┌───────────────────────────────────────┐
│          User's Machine                │
│  Hub + Agents + TTS + STT             │
│  (Apple Silicon or NVIDIA GPU)        │
│  Kokoro via mlx-audio (Mac)           │
│  or kokoro-fastapi (NVIDIA)           │
│  Whisper via whisper.cpp (Mac)        │
│  or faster-whisper (NVIDIA)           │
└───────────────────────────────────────┘
```

- Everything on one machine, works offline
- Mac: mlx-audio for TTS (~3x realtime on M4+), whisper.cpp with CoreML for STT
- NVIDIA: kokoro-fastapi for TTS, faster-whisper for STT
- Best for: privacy-focused users, offline use, powerful laptops
- Requires: Apple Silicon (M3 Pro+) or NVIDIA GPU (RTX 3070+ with 8GB+ VRAM)

## Hardware Requirements

| Mode | Device | GPU | RAM | Network |
|------|--------|-----|-----|---------|
| Thin Client | Any (browser) | None | 2GB | Required |
| Split | Mac/Linux/Windows | None locally | 8GB+ | Required (to GPU server) |
| Fully Local (Mac) | M3 Pro or better | Integrated | 16GB+ | None |
| Fully Local (NVIDIA) | Any with GPU | RTX 3070+ (8GB) | 16GB+ | None |

## Quality Modes

Users should be able to choose a quality/performance tradeoff, especially on lower-end hardware:

| Quality | Whisper Model | Kokoro Speed | Latency | VRAM |
|---------|--------------|-------------|---------|------|
| High | large-v3-turbo | Full quality | ~200ms | 6GB+ |
| Medium | medium | Slightly faster | ~150ms | 3GB+ |
| Low | small | Fast, lower accuracy | ~100ms | 1.5GB+ |
| Tiny | tiny | Fastest | ~50ms | <1GB |

Quality mode should be configurable per-user in the settings UI and stored in the project config. This allows users with weaker hardware (like an 8GB 3070 Ti) to drop to medium quality to free up VRAM for other tasks, or users on CPU-only to use tiny for acceptable latency.

## 3070 Ti Compatibility

An RTX 3070 Ti with 8GB VRAM can run both Kokoro TTS and Whisper STT, but not simultaneously with large models. Recommended setup:

- Whisper: large-v3-turbo (fits in 8GB) or medium for headroom
- Kokoro: runs alongside Whisper with room to spare
- Performance: comparable to RTX 3090, slightly lower throughput
- Use Medium quality mode if running other GPU workloads simultaneously

## Installer

For public release, ClawMux needs a clean installer that:

1. Detects the user's hardware (Apple Silicon, NVIDIA, CPU-only)
2. Installs the right TTS/STT backends automatically
3. Sets up the hub and default project
4. Configures the deployment mode based on available hardware
5. Provides a single command to start everything: `clawmux start`

## Renaming

The codebase needs cleanup:

- Rename the git repo folder from `voice-chat` to `clawmux`
- Rename the MCP server from `voice-hub` to `clawmux`
- Update all references in CLAUDE.md files, skills, and documentation

## Session Transfer Between Instances

Users need to seamlessly transfer between two ClawMux instances. Example: start a conversation on workstation, continue on Mac. This requires:

- **History sync**: Conversation history needs to be portable between instances (already stored as JSON files)
- **Agent state transfer**: Agent roles, assignments, and context need to move with the session
- **Config portability**: Project settings, voice assignments, deployment config should be shareable
- **Real-time handoff**: Ideally, one instance can "hand off" to another without losing the conversation flow

Research needed on the best approach: file sync (rsync/git), real-time replication, or export/import mechanism.

## Current Status

The hub is fully functional on workstation (Mode 1/2 already work). Mode 3 needs mlx-audio and whisper.cpp integration. The installer is not started. Renaming is a straightforward find-and-replace task.
