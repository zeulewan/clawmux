# Configuration

## Server Settings

Configuration is set via constants in `mcp_server.py` and environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_URL` | `http://127.0.0.1:2022` | Whisper STT server base URL |
| `KOKORO_URL` | `http://127.0.0.1:8880` | Kokoro TTS server base URL |
| `WS_PORT` / `VOICE_CHAT_PORT` | `3456` | WebSocket / HTTP server port |

The port can be overridden via the `VOICE_CHAT_PORT` environment variable.

## Voice Services

### Whisper STT

The server forwards audio to Whisper's OpenAI-compatible endpoint:

```
POST {WHISPER_URL}/v1/audio/transcriptions
```

Whisper accepts WebM, WAV, MP3, and other common audio formats. The browser records in WebM/Opus by default.

### Kokoro TTS

The server requests speech from Kokoro's OpenAI-compatible endpoint:

```
POST {KOKORO_URL}/v1/audio/speech
```

#### Available Voices

| Voice | Description |
|-------|-------------|
| `af_sky` | Female (default) |
| `af_alloy` | Female |
| `af_sarah` | Female |
| `am_adam` | Male |
| `am_echo` | Male |
| `am_onyx` | Male |
| `bm_fable` | Androgynous |

Change the voice by passing the `voice` parameter to `converse()`.

## Tailscale Setup

### Expose the Server

```bash
sudo tailscale serve --bg --https=3456 http://127.0.0.1:3456
```

This creates an HTTPS endpoint with automatic TLS certificates. Tailscale also upgrades WebSocket connections to WSS automatically.

### Verify

```bash
tailscale serve status
```

### Remove

```bash
sudo tailscale serve --https=3456 off
```

## Logging

Server logs are written to `/tmp/voice-chat.log` and stderr. Watch in real time:

```bash
tail -f /tmp/voice-chat.log
```

## Ports Summary

| Port | Service | Protocol |
|------|---------|----------|
| 3456 | Voice Chat (MCP server) | HTTP + WebSocket (localhost) / HTTPS + WSS (Tailscale) |
| 2022 | Whisper STT | HTTP (localhost only) |
| 8880 | Kokoro TTS | HTTP (localhost only) |
