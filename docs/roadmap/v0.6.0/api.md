# Public API

Voice Hub exposes a REST + WebSocket API for any client — browser, iOS app, desktop, or third-party integrations.

## Current Protocol

**REST**: Sessions CRUD, voice/speed changes, chat history, settings, debug stats, transcription.

**WebSocket** (`ws://host:3460/ws`): JSON messages with `type` field. Client sends audio, text, playback events. Hub sends session state, audio, transcripts, status updates.

Full protocol reference: [agents reference](../../agents/reference/protocol.md)

## v0.6.0 Changes

### Authentication

Token-based. Hub generates a token on first run (stored in `data/settings.json`). Passed as query param on WebSocket or Bearer token on REST.

### Versioning

REST endpoints prefixed with `/v1/`. WebSocket messages get a `version` field. Unversioned endpoints remain for backward compatibility.

### New Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/v1/agents` | List agents with status, workers, inbox counts |
| POST | `/v1/agents/{id}/message` | Send a message to an agent |
| GET | `/v1/agents/{id}/inbox` | Read pending messages |
| POST | `/v1/agents/{id}/workers` | Spawn a worker |
| GET | `/v1/agents/{id}/workers` | List workers |

### New WebSocket Events

`worker_spawned`, `worker_terminated`, `agent_message`, `agent_status`
