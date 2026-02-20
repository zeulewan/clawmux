# iOS Implementation Backlog

Work items for the iOS app. **Delete each item after completing it.** When this file is empty, the app is caught up with the web client.

**Note:** Some of these features may already be partially or fully implemented. Read the current codebase first and use your discretion — skip or delete items that are already done, and adapt the remaining ones to fit the existing implementation.

## Sync with Web Client

These items bring the iOS app in line with the current web client behavior.

### Remove Tab Bar

The web client no longer has a tab bar. Navigation is via the voice grid (landing page). Remove:

- `sessionTabBar` view and `sessionTab()` function from `ContentView.swift`
- The "+" New button (spawning is done from voice cards)
- The Debug tab button (move to header or settings)

Replace with a debug link in the header bar (small text, like the web client's header).

### Show Active Voice Name in Header

When viewing a session, display the voice name (e.g. "Sky") in the header bar next to "Voice Hub". Hide it when on the voice grid.

### Fetch Message History from Server

Messages are persisted server-side per voice. On session open, fetch history instead of starting with an empty chat.

- `GET /api/history/{voice_id}` returns `{"voice_id": "...", "messages": [{role, text, ts}, ...]}`
- In `addSessionFromDict()`, fetch history and populate `session.messages` with it
- In `switchToSession()`, optionally re-fetch to pick up messages from other clients

### Reset History

Add a way to clear a voice's history:

- `DELETE /api/history/{voice_id}` clears it
- Add to a context menu (long-press on voice card) or a button in the session view
- After clearing, empty local `session.messages` and re-render

### Unread Badge on Voice Cards

When a background session has activity (audio buffered, pending listen), show a small red dot on its voice card. The web client uses `session.hasUnread` for this.

### Background Audio Buffering

The web client buffers audio for background sessions and plays it when you switch to that tab. The iOS app currently ignores audio for non-active sessions (line 497: `if sid == activeSessionId`). Add:

- `audioBuffer: [Data]` to `VoiceSession`
- Buffer audio when `sid != activeSessionId`
- Play buffered audio on `switchToSession()`
- Send `playback_done` after all buffered audio plays

### Auto Interrupt Toggle

The web client has an "Auto Interrupt" toggle (voice-based interrupt during playback). The iOS app is missing this. Add:

- `autoInterruptEnabled` published var
- During playback, monitor mic for sustained speech (like the web client's `startPlaybackVAD`)
- If speech detected for 300ms, interrupt and start recording
- Toggle in settings or controls

### Controls Bar Cleanup

Match the web client's minimal controls:

- Remove tmux session name display (line 308-312)
- Move toggles and voice/speed pickers into an options menu or sheet
- Big mic button with colored glow matching state (blue=record, green=send, orange=interrupt)

### Mic Mute

The web client has a mic mute toggle. When muted, `sendSilentAudio()` is called instead of recording. Add:

- `micMuted` published var
- When muted and `listening` received, send empty audio
- Toggle in options/settings

### Voice Card States

The web client shows detailed voice card states (thinking, speaking, listening). The iOS app shows basic states. Update `voiceCardLabel` and `voiceCardDotColor` to match:

- Thinking (orange, pulsing) — when `session.isThinking`
- Speaking (blue) — when status text is "Playing..." or "Speaking..."
- Listening (red) — when status text is "Recording..." or "Tap Record" or `pendingListen`

### Handle Heartbeat Pings

The hub sends `{"type": "ping"}` every 30 seconds to all connected clients. The iOS app should:

- Ignore `ping` messages in the WebSocket message handler (don't process them as unknown types)
- Track the last ping time. If no ping received for ~60 seconds, assume the connection is dead and reconnect
- On reconnect, hub sends a fresh `session_list` — use it to rebuild state

### Multi-Client Sync

The hub now supports multiple simultaneous clients. The iOS app no longer "replaces" the browser — both can be connected at the same time and receive the same messages. Remove any "single client" assumptions if present.

### Voice Grid as Landing Page

On app launch and reconnect, show the voice grid (not a session view). When tapping a voice card:

- If the voice already has an active session → switch to its chat view immediately
- If no session exists → spawn one (see Spawn Flow below)

The server rejects duplicate voice spawns (returns 503 if that voice already has a session).

### Spawn Flow

Spawning a session is a long-running operation (~30-60 seconds). The `POST /api/sessions` request blocks until the session is ready or times out. The iOS app must handle this correctly:

1. User taps an inactive voice card
2. Show "Spawning..." on the card immediately (local UI state)
3. Call `POST /api/sessions` with `{"voice": "af_sky"}` — **set a long URLSession timeout (90s+)**, this request takes ~30-60s
4. The response comes back with `status: "ready"` and the full session object
5. Add the session to local state and switch to its chat view
6. If the request fails (503 = duplicate voice, 504 = timeout, network error), show an error and clear the "Spawning..." state

**Important:** While the POST is pending, the WebSocket may also send `session_status` messages for the session. You can use either the REST response or the WebSocket `session_status` with `status: "ready"` to trigger the switch — whichever arrives first. The session object from the REST response is the authoritative one.

Do NOT use a short timeout on the spawn request — the default URLSession timeout (60s) may be too short. Use at least 90 seconds.

### Connection Status Indicator

The header shows a connection status dot and label:

- **Connecting** — pulsing yellow dot, "Connecting..." text (on app launch / reconnect)
- **Connected** — green dot, "Connected" text
- **Disconnected** — red dot, "Disconnected" text

Show this in the app's header or status area.

### Waveform Visualizer

The web client shows a live audio waveform while recording. Use `AVAudioEngine`'s input tap to get audio levels and render a waveform (oscilloscope style) or level meter above the mic button during recording. Color it with the active voice's color. Hide when not recording.

### Chat Display Cap

Only render the last 50 messages in the chat view. The server stores up to 200 per voice, but displaying all of them is unnecessary. New messages during the session still append live.

### Settings Page

The web client has a dedicated settings page (accessible from header) with persistent server-side settings. Add a settings view to the iOS app:

- Fetch settings on launch: `GET /api/settings`
- Model picker (Opus/Sonnet/Haiku) — changes apply to new sessions only
- Auto Record, Auto End, Auto Interrupt toggles
- Save changes via `PUT /api/settings` with partial JSON
- Settings are shared across all clients (browser + iOS)

### Device Switching

The hub supports seamless device switching mid-conversation. If the user closes the browser while an agent is speaking or listening, and then opens the iOS app:

- The hub waits for a client to reconnect (no timeout, no error)
- When the iOS app connects, the hub re-sends `listening` every 5 seconds until a client responds
- Audio that was playing on the old device is skipped — the conversation continues from the listen phase
- The app should handle receiving `listening` messages for sessions it didn't initiate — switch to the session or mark it as pending

### Voice Colors

Each voice has a unique accent color. Use these for the voice name text on cards and as a left border on assistant chat bubbles:

| Voice | Color |
|-------|-------|
| Sky | `#3a86ff` (blue) |
| Alloy | `#e67e22` (orange) |
| Sarah | `#e63946` (red) |
| Adam | `#2ecc71` (green) |
| Echo | `#9b59b6` (purple) |
| Onyx | `#1abc9c` (teal) |
| Fable | `#f1c40f` (gold) |
