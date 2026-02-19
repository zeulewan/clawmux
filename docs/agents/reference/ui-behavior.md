# UI Behavior Reference

Detailed reference for every state, button, toggle, and audio behavior in the Voice Hub browser UI.

## Pages

The UI has three views, controlled by the tab bar:

| View | Tab | Description |
|------|-----|-------------|
| **Home** | Home (always visible, left side) | Voice card grid showing all voices and their status |
| **Session** | Per-session tab (created on spawn) | Chat transcript + controls for one agent |
| **Debug** | Debug (always visible, right side) | Hub internals, services, tmux, logs |

Only one view is visible at a time. The Home tab is active by default on page load.

## Voice Cards (Home Page)

Each of the 7 voices (Sky, Alloy, Sarah, Adam, Echo, Onyx, Fable) gets a card. Cards show real-time status.

### Card States

| State | Dot Color | Label | Trigger |
|-------|-----------|-------|---------|
| Available | Grey | "Available" | No session exists for this voice |
| Spawning | Yellow | "Spawning..." | User clicked the card, REST call in progress |
| Starting | Yellow | "Starting..." | Session created, Claude booting, MCP not yet connected |
| Ready | Green | "Ready" | MCP connected, session idle |
| Thinking | Orange (pulsing) | "Thinking..." | Agent is processing (between user send and agent response) |
| Speaking | Blue | "Speaking..." | Agent audio is playing (or buffered for background session) |
| Listening | Red | "Listening..." | Session is recording or waiting for Record tap |
| Waiting | Red | "Waiting..." | Background session needs mic input but isn't focused |

### Card Interactions

- **Click an Available card** — Spawns a new session with that voice. Card immediately shows "Spawning..." and won't accept double-clicks.
- **Click a connected card** — Switches to that session's tab.

## Session Tabs

Each active session gets a tab in the tab bar between Home and Debug.

### Tab Elements

- **Status dot** — Color matches session state (green=ready, yellow=starting, blue=active)
- **Label** — Voice display name (e.g. "Sky", "Adam")
- **Badge (!)** — Red badge, appears when a background session has buffered audio or is waiting for mic input
- **Close (x)** — Terminates the session (kills tmux, cleans up temp dir)

### Tab Switching Behavior

When switching away from a session:

1. Currently playing audio **pauses** and is saved on the session for resume
2. Any buffered playback chain **stops** (remaining chunks stay in buffer)
3. Active recording is **discarded** (not sent)
4. Thinking sound **stops**
5. Pending listen request is **cleared**

When switching to a session:

1. If the session had **paused audio**, it resumes playback from where it stopped
2. If the session has **buffered audio** (received while in background), it plays all chunks in sequence
3. If the session has a **pending listen** request:
   - Mic muted → sends silent audio automatically
   - Auto Record on → starts recording immediately
   - Auto Record off → shows "Tap Record" status, waits for manual click
4. Tab **badge clears** on switch
5. **Thinking sound resumes** if the session is in thinking state
6. Voice and speed dropdowns update to match the session's settings
7. Tmux session name appears in the bottom bar

## Main Button

The center button cycles through states based on context:

| Button State | Color | Label | When |
|-------------|-------|-------|------|
| Record | Blue | "Record" | Idle, ready for input |
| Send | Green | "Send" | Currently recording |
| Interrupt | Orange | "Interrupt" | Audio is playing |
| Processing | Grey | "Processing..." | Audio sent, waiting for Claude |

### Button Click Actions

- **Record** → Starts recording. If there's a pending listen from the hub, records for that request. Otherwise starts a freeform recording for the active session.
- **Send** → Stops recording and sends audio to the hub for STT.
- **Interrupt** → Immediately stops audio playback, sends `playback_done` to the hub so it can proceed to the listening phase. Status resets to "Ready".
- **Processing** → Disabled (no click action). Button shows this state after audio is sent until Claude responds.

### Cancel Button (X)

Visible only during recording (next to the main button). Discards the recording and sends silent audio to the hub so it doesn't hang waiting for input.

## Toggles

### Auto Record

**Default: off.** When enabled, recording starts automatically after Claude finishes speaking (after `playback_done`). When disabled, the user must click Record manually — the status shows "Tap Record" and a listening cue plays.

### Auto End (VAD)

**Default: on.** Voice Activity Detection. When enabled during recording, monitors the mic for silence. After detecting speech followed by 3 seconds of silence (RMS < 10), automatically stops recording and sends the audio. The Send button is always available for early manual send.

VAD constants:

- `SILENCE_THRESHOLD = 10` — RMS level below which counts as silence
- `SILENCE_DURATION = 3000` — Milliseconds of continuous silence before auto-stop
- Only triggers after speech has been detected (won't auto-stop on initial silence)

### Auto Interrupt

**Default: off.** When enabled, monitors the mic during audio playback for speech. If sustained speech is detected (300ms above threshold), automatically interrupts playback and starts recording. Designed for natural conversation flow — speak over Claude to interrupt.

Playback VAD constants:

- `SPEECH_THRESHOLD = 25` — Higher than Auto End's threshold to avoid speaker audio bleeding into the mic and causing false triggers
- `SPEECH_DURATION = 300` — Milliseconds of sustained speech before interrupting
- Check interval: 50ms (more responsive than Auto End's 100ms)
- Only active when Auto Interrupt is on AND mic is not muted AND audio is playing

### Mic Mute

**Global toggle** (not per-session). When muted:

- The Mic button shows "Muted" with a red border
- Persistent mic stream tracks are disabled
- Any session that requests mic input receives silent audio automatically
- The hub treats empty audio as "(session muted)" and Claude gets that text

## Audio Behavior

### Focused Session

When the active session tab is focused:

- **TTS audio plays immediately** through the browser
- After playback, hub sends `listening` and the browser either auto-records or waits for Record click
- **Thinking sound plays** — Soft double-tick pattern (1200Hz + 900Hz tones, every 800ms) while Claude is processing
- **Thinking indicator shows** — Three pulsing dots in the chat transcript

### Background Session

When a session is NOT the active tab:

- **Audio is buffered** — TTS audio chunks are stored in `s.audioBuffer` instead of playing. Badge (!) appears on the tab.
- **Listen requests are deferred** — Session is marked with `pendingListen = true`, badge appears. Listen activates when user switches to that tab.
- **Thinking sound does NOT play** — Only plays for the focused session
- **Thinking indicator is tracked** — `s.isThinking` is set, so the indicator appears immediately when switching to the tab
- **Status text updates** — `s.statusText` is kept current even for background sessions so the Home page voice cards show accurate state

### Tab Switch Audio Resume

When switching to a session with buffered or paused audio:

1. **Paused audio** (was playing when you switched away) — resumes from the pause point
2. **Buffered audio** (received while in background) — plays all chunks sequentially, then sends `playback_done`
3. Both paths support Auto Interrupt if enabled

### Audio Cues

Short tones played via Web Audio API:

| Cue | Sound | When |
|-----|-------|------|
| Listening | Ascending two-tone (660Hz → 880Hz) | Hub requests mic input |
| Processing | Single soft low tone (440Hz) | Audio sent to hub |
| Session ready | Three-note chime (C5 → E5 → G5) | MCP connects, session becomes ready |
| Thinking | Double-tick (1200Hz + 900Hz, repeating) | Claude is processing (focused session only) |

## Chat Transcript

Each session has its own message history, persisted to `localStorage`.

### Message Types

| Type | Alignment | Style | Source |
|------|-----------|-------|--------|
| User | Right | Blue bubble | `user_text` from hub (after STT) |
| Assistant | Left | Dark bubble | `assistant_text` from hub (before TTS) |
| System | Center | Grey, no bubble | Session events (connected, ended) |
| Thinking | Left | Dark bubble with pulsing dots | Shown while Claude is processing |

### Thinking Indicator

Three animated dots that pulse in sequence. Appears after user sends audio (when `user_text` is received from hub). Disappears when `assistant_text` or `done` is received. Survives tab switches — if you switch away and back, the dots reappear if the session is still thinking.

## Session Lifecycle

### Spawn Flow

1. User clicks voice card or "+ New Session"
2. Card shows "Spawning..." immediately (before server responds)
3. REST `POST /api/sessions` creates tmux session
4. Tab appears, switches to session view, shows "Waiting for Claude..."
5. Claude boots in tmux, MCP server connects to hub
6. Hub sends `session_status: ready` → tab dot turns green, "Claude connected." system message, ready chime plays
7. Hub sends `/voice-hub` to tmux → Claude enters voice mode and greets user

### Session End

Two ways a session ends:

- **User closes tab** — `DELETE /api/sessions/{id}`, kills tmux, removes temp dir
- **Agent says goodbye** — Hub sends `session_ended`, "Session ended." system message appears, session auto-terminates after 3 seconds

### Inactivity Timeout

Sessions auto-terminate after 30 minutes of no activity (configurable via `VOICE_CHAT_TIMEOUT`). Activity is tracked by `session.touch()` on converse calls and browser messages.

## WebSocket Connection

Single WebSocket between browser and hub. Shown in the header:

- **Green dot + "Connected"** — WebSocket is open
- **Red dot + "Disconnected"** — WebSocket is closed, auto-reconnects every 2 seconds

On disconnect, all sessions with pending `playback_done` waits are unblocked so `converse()` calls don't hang forever.

## Debug Panel

Shows hub internals with auto-refresh every 5 seconds:

- **Hub** — Port, uptime, browser connection status, session count
- **Services** — Whisper and Kokoro URLs and connectivity
- **Hub Sessions** — ID, voice, status, MCP connected, idle time, age, work directory
- **tmux Sessions** — All tmux sessions (voice and non-voice), window count, attached status
- **Hub Log** — Last 50 lines of `/tmp/voice-chat-hub.log`

Switching to the Debug tab stops audio and recording from the current session (same cleanup as switching to any other view).

## Voice and Speed

### Voice Selection

Per-session dropdown. 7 Kokoro voices available:

| Voice ID | Display Name | Gender |
|----------|-------------|--------|
| `af_sky` | Sky | F |
| `af_alloy` | Alloy | F |
| `af_sarah` | Sarah | F |
| `am_adam` | Adam | M |
| `am_echo` | Echo | M |
| `am_onyx` | Onyx | M |
| `bm_fable` | Fable | - |

When spawning sessions, the hub auto-rotates through unused voices so each session starts with a different voice. Changing the voice updates the tab label and sends a `PUT /api/sessions/{id}/voice` to the hub.

### Speed Selection

Per-session dropdown. Options: 0.75x, 1x (default), 1.25x, 1.5x, 2x. Sends `PUT /api/sessions/{id}/speed` to the hub. Affects Kokoro TTS generation speed.

## Persistence

- **Chat messages** — Saved to `localStorage` per session. Restored on page reload if the session still exists.
- **Toggle states** — Not persisted. Auto Record defaults to off, Auto End defaults to on, Auto Interrupt defaults to off on each page load.
- **Sessions** — Hub sends the session list on WebSocket connect, so existing sessions appear on page reload.
