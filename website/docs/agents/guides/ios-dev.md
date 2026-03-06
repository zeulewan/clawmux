# iOS Development

You are building a native iOS app that connects to the ClawMux as a client, replacing the browser UI.

## How It Works

The iOS app connects to the same hub WebSocket as the browser. The hub doesn't care what client is connected. Your job is to implement the same state machine and audio handling, but in Swift/SwiftUI.

## Reference Docs

Read these before writing any code:

| Document | What you'll learn |
|----------|-------------------|
| [WebSocket Protocol](../reference/protocol.md) | Every message type, the converse flow sequence, session object schema, REST API |
| [UI Behavior](../reference/ui-behavior.md) | All states, button behaviors, toggles, audio handling |
| [Hub Architecture](../reference/hub.md) | How the hub works, what it expects from clients |

## Key Files

The app has two main source files:

```
ios/VoiceHub/VoiceHubViewModel.swift   # All state: WebSocket, audio, recording, Live Activity
ios/VoiceHub/ContentView.swift          # All UI: voice grid, session view, settings, debug
```

Supporting files:

```
ios/project.yml                          # XcodeGen project definition
ios/VoiceHub/Info.plist                 # Background modes, permissions, URL schemes
ios/VoiceHubShared/VoiceHubActivityAttributes.swift  # ActivityKit (shared with widget)
ios/VoiceHubWidget/VoiceHubLiveActivity.swift         # Dynamic Island + Lock Screen
```

## Build & Deploy Workflow

The development cycle is: edit code, build, install, launch.

```bash
# Build (from ios/ directory)
xcodebuild -project VoiceHub.xcodeproj -scheme VoiceHub \
  -destination 'id=DEVICE_ID' 2>&1 | grep -E '(BUILD|error:)'

# Install
xcrun devicectl device install app --device DEVICE_ID \
  ~/Library/Developer/Xcode/DerivedData/VoiceHub-*/Build/Products/Debug-iphoneos/VoiceHub.app

# Launch (phone must be unlocked)
xcrun devicectl device process launch --device DEVICE_ID com.zeul.voicehub
```

Find device ID with `xcrun xctrace list devices`.

After editing `project.yml`, regenerate with `xcodegen generate` before building.

**SourceKit diagnostics**: The Swift SourceKit language server reports false errors ("Cannot find type 'VoiceHubViewModel' in scope", etc.) due to stale indexing. Ignore these. Only trust `xcodebuild` output for real errors.

## Architecture

### Input Modes

The app supports three input modes, switchable via a mode pill in the session view:

- **Auto** - Mic opens automatically after agent speaks, VAD stops recording on silence
- **PTT** - Hold-to-talk with 4-direction drag gestures (see PTT Gestures below)
- **Typing** - Text-only, no audio

### PTT Gestures

Four-direction gesture system on the mic button while recording:

| Gesture | Action | Audio sent to hub? |
|---------|--------|--------------------|
| **Swipe UP** | Send audio immediately | Yes (as audio) |
| **Swipe LEFT** | Cancel recording, discard | No |
| **Swipe RIGHT** | Open keyboard with transcription | No (sent as text after editing) |
| **Just release** | Show inline transcript preview | No (user decides) |

**Transcript preview** is an intermediate state between the mic button and keyboard. After releasing:
- Shows transcription spinner, then the recognized text
- Tap the transcript text to open keyboard and edit
- Tap send button to send as text immediately
- Tap X to dismiss and return to normal mic
- Press mic again to discard preview and start new recording

**Keyboard return**: Dismissing the keyboard (X button) returns to transcript preview if text exists, rather than fully dismissing.

**Direction hints during recording**: Left shows "Cancel" label, right shows "Aa" keyboard hint, mic label updates to reflect current drag direction.

**Auto mode parallel transcription**: When audio is sent to the hub (via swipe-up or auto-mode), a parallel `/api/transcribe` call fires to show the user what they said while waiting for the agent response. Cleared when the hub echoes back `user_text`.

### Audio Session

```swift
.playAndRecord, mode: .spokenAudio,
options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .allowBluetoothHFP, .mixWithOthers]
```

### Background Keepalive

Dual-layer keepalive to prevent iOS suspension:

1. **AVAudioEngine** with continuous input tap (primary - active audio processing)
2. **Silent AVAudioPlayer loop** (secondary - ensures audio session stays active)

Both start on background entry, stop on foreground return. Interruption handler re-activates session and restarts engine on `.ended`.

### Recording

Uses `AVAudioRecorder` (not AVAudioEngine) for actual recording: 16kHz, mono, 16-bit PCM to a temp file. VAD runs via a separate `AVAudioEngine` input tap that monitors RMS levels.

### Playback

TTS audio arrives as base64 MP3 via WebSocket `audio` messages. Decoded and played via `AVAudioPlayer`. Audio for non-active sessions is buffered and played on switch.

### Live Activity

ActivityKit with `VoiceHubActivityAttributes`. Started/updated/ended from ViewModel at state transitions. Per-mode toggle (auto and PTT only).

## Connection Details

- **WebSocket**: `wss://{hostname}:{port}/ws`
- **REST API**: `https://{hostname}:{port}/api/...`
- **Transcription**: `POST /api/transcribe` - accepts raw audio bytes, returns `{"text": "..."}`
- Hub sends `ping` every 30s. On reconnect, hub sends `session_list` with full state.

## Settings

Per-mode settings pages (Auto, PTT, Typing) with relevant toggles for each mode:

- Input controls (auto-record, VAD, interrupt, record-while-thinking)
- Sounds (thinking, listening cue, processing cue, session ready)
- Haptics (recording, playback, send, session events)
- Notifications (background agent response alerts)
- Live Activity toggle

## Audio Format

- **Playback**: Hub sends base64-encoded MP3
- **Recording**: App records WAV (16kHz PCM), hub sends to Whisper which accepts it
- **Transcription preview**: `POST /api/transcribe` with raw audio bytes for PTT text preview
