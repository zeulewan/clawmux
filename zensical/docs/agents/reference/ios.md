# iOS App

Native iPhone companion app for ClawMux. Connects to the hub over WebSocket and provides a multi-session voice interface with three input modes.

**Status:** Beta (v0.5.0)

## Features

### Input Modes
- **Auto** - Mic opens automatically after the agent speaks, VAD auto-stops on silence
- **Push to Talk (PTT)** - Hold mic button to record with 4-direction gestures:
  - Swipe up: send audio immediately
  - Swipe left: cancel recording
  - Swipe right: open keyboard with transcription for editing
  - Release: show inline transcript preview (tap to edit, send, or dismiss)
- **Typing** - Keyboard input, no voice/TTS
- Mode toggle in the session view (tap the mode pill below the mic button)

### Voice Sessions
- Multi-session support with voice grid landing page
- Voice card states: Thinking (orange), Speaking (blue), Listening (red), Ready (green)
- Chat transcript with persistence across restarts
- Voice selection (7 Kokoro voices) and speed control (0.75x-2x) per session
- Context menu on voice cards to terminate or reset history

### Audio
- Background audio with dual keepalive (AVAudioEngine input tap + silent audio loop)
- Background recording with auto-record in auto mode
- Audio buffering for background sessions, played on switch
- Interrupt playback by tapping mic during speech
- Audio cues: thinking tick, listening cue, processing cue, session ready chime
- Per-mode sound and haptics toggles

### Live Activity
- Dynamic Island: session status dot + voice name
- Lock Screen: voice name, status, last message preview
- Per-mode toggle (auto and PTT only, typing uses notifications)

### PTT Extras
- 4-direction gesture: up=send, left=cancel, right=keyboard, release=preview transcript
- Inline transcript preview with send/edit/dismiss after recording
- Keyboard mode with mic button for additional voice-to-text
- Dismissing keyboard returns to transcript preview if text exists
- Parallel transcription on send shows what you said while waiting for response

### Navigation
- Left-edge swipe to go back to hub from session view
- Swipe-back reveals home view underneath (no black flash)

## Requirements

- iPhone running iOS 17.0+
- Xcode 16+ (with iOS platform SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Developer account (free works, apps expire every 7 days)

## Build & Deploy

The development workflow uses three commands: build, install, launch.

### One-time setup

```bash
cd ios/
xcodegen generate
```

Find your device ID:

```bash
xcrun xctrace list devices
```

### Build

```bash
cd ios/
xcodebuild -project VoiceHub.xcodeproj -scheme VoiceHub \
  -destination 'id=DEVICE_ID' 2>&1 | grep -E '(BUILD|error:)'
```

Use `generic/platform=iOS` as the destination if you just want to verify compilation without a connected device.

### Install

```bash
xcrun devicectl device install app \
  --device DEVICE_ID \
  ~/Library/Developer/Xcode/DerivedData/VoiceHub-*/Build/Products/Debug-iphoneos/VoiceHub.app
```

### Launch

```bash
xcrun devicectl device process launch \
  --device DEVICE_ID \
  com.zeul.voicehub
```

Phone must be unlocked for remote launch to work.

On first install, go to **Settings > General > VPN & Device Management** and trust the developer certificate.

### All-in-one

```bash
cd ios/ && \
xcodebuild -project VoiceHub.xcodeproj -scheme VoiceHub \
  -destination 'id=DEVICE_ID' 2>&1 | grep -E '(BUILD|error:)' && \
xcrun devicectl device install app --device DEVICE_ID \
  ~/Library/Developer/Xcode/DerivedData/VoiceHub-*/Build/Products/Debug-iphoneos/VoiceHub.app && \
xcrun devicectl device process launch --device DEVICE_ID com.zeul.voicehub
```

## Configuration

On launch, tap the gear icon and enter your hub URL with port:

```
workstation.tailee9084.ts.net:3460
```

The app connects via WebSocket (`ws://` or `wss://` depending on scheme). Tailscale direct connections work.

## Project Structure

```
ios/
  project.yml                  # XcodeGen project definition
  VoiceHub/
    Info.plist                 # Background modes, permissions, URL schemes
    VoiceHubApp.swift         # SwiftUI app entry point
    VoiceHubViewModel.swift   # WebSocket, audio, state, Live Activity, recording
    ContentView.swift          # UI (voice grid, session view, settings, debug)
    Assets.xcassets/           # App icon, colors
  VoiceHubShared/
    VoiceHubActivityAttributes.swift  # ActivityKit attributes (shared with widget)
  VoiceHubWidget/
    Info.plist                 # Widget extension Info.plist
    VoiceHubWidgetBundle.swift  # Widget entry point
    VoiceHubLiveActivity.swift  # Dynamic Island + Lock Screen UI
```

### Key architecture

- **VoiceHubViewModel** (~2400 lines) - All state management. WebSocket connection, audio session, recording (AVAudioRecorder), playback (AVAudioPlayer), Live Activity lifecycle, background keepalive, VAD, tone player, notifications.
- **ContentView** (~1350 lines) - All UI. Voice grid, session view with chat, three bottom control variants (auto/PTT controls, PTT text input, typing text input), settings (per-mode pages), debug panel.

## Settings Structure

Settings are organized by input mode:

- **Auto** - Auto record, VAD + tuning, auto interrupt, record while thinking, sounds, haptics, notifications, Live Activity
- **PTT** - Record while thinking, sounds, haptics, notifications, Live Activity
- **Typing** - Haptics, notifications

Global settings (server, model, background mode) are on the root settings page.

## Background Audio

The app uses `UIBackgroundModes: audio` with a layered keepalive strategy (modeled after the OpenClaw approach):

1. **Primary: AVAudioEngine** with a continuous input tap that keeps the audio processing pipeline alive. iOS won't suspend apps with active audio engine work.
2. **Secondary: Silent audio loop** via AVAudioPlayer (8kHz, 1s, near-silent WAV, volume 0).
3. **Audio session**: `.playAndRecord` with `.spokenAudio` mode, Bluetooth support, 48kHz preferred sample rate.
4. **Interruption recovery**: On audio session interruption end, re-activates the session and restarts the keepalive engine if it died.

Both keepalive mechanisms start when the app backgrounds with active sessions, and stop when returning to foreground.

## Persistence

All state is saved to UserDefaults:

| Key | Type | Description |
|-----|------|-------------|
| `serverURL` | String | Hub connection URL |
| `inputMode` | String | auto, ptt, or typing |
| `autoRecord` | Bool | Auto-record after assistant speaks |
| `vadEnabled` | Bool | Voice activity detection |
| `backgroundMode` | Bool | Background keepalive enabled |
| `liveActivityAuto` | Bool | Live Activity for auto mode |
| `liveActivityPTT` | Bool | Live Activity for PTT mode |
| `voice-hub-chats` | JSON | Chat messages per session |
| `sessionPrefs` | JSON | Per-session voice and speed |
| Sound/haptic toggles | Bool | Per-mode audio cue and haptic settings |

## Pending Feature Parity

Features added to the web client that are not yet in the iOS app. These are tracked here so that future iOS development stays in sync.

### Karaoke Word Highlighting

The web client highlights each word in assistant messages in real-time as it is spoken, using word-level timestamps from Kokoro's `/dev/captioned_speech` endpoint.

**How it works (web):**
- The hub calls `/dev/captioned_speech` instead of plain TTS, which returns `{audio: base64_mp3, timestamps: [{word, start_time, end_time}]}`
- The `audio` WebSocket message now includes a `words` field alongside `data`
- Browser spans each word in the latest assistant message, then a 60fps RAF loop highlights the current word based on `audioCtx.currentTime - startTime`
- Active word gets `text-shadow` (bold effect without layout shift) + voice-color background highlight
- Words are saved and re-applied when switching sessions mid-playback

**iOS implementation notes:**
- Use the new `/api/tts-captioned` endpoint (POST `{text, voice, speed}`, returns `{audio_b64, words}`) instead of `/api/tts`
- For live speech from the hub, parse the `words` field from the `audio` WebSocket message
- Use `AVAudioPlayer.currentTime` as the clock, drive updates with a `CADisplayLink` (60fps)
- Highlight the current word by applying an `AttributedString` overlay or animating text color/weight in the chat view
- Preserve word list across session switches — re-apply to the last assistant message when switching back

### Audio Resume on Session Switch (Seek)

The web client saves the playback offset when you switch away from a session mid-speech, then seeks to that offset when you return.

**How it works (web):**
- On session switch, remaining audio chunks are stashed to `s.audioBuffer` with an `{offset: elapsed}` marker
- On return, `playAudio` calls `source.start(0, offset)` to seek into the buffer
- Karaoke timestamps are adjusted by the same offset so highlighting stays in sync

**iOS implementation notes:**
- iOS already buffers audio for background sessions and replays on switch
- Add seek: save `player.currentTime` before stopping, store with the audio data, call `player.currentTime = savedOffset` before `play()` on resume
- `AVAudioPlayer` supports seeking via `currentTime` property

### Mute Button

The web client has a mute toggle that suppresses mic input (auto-record is suspended) without changing the input mode. The button occupies the same space as the cancel button so the layout doesn't shift when recording starts.

**iOS implementation notes:**
- Add a `micMuted` boolean to ViewModel
- When muted: skip auto-record, send silent audio to unblock the agent if it's waiting for input, show a visual indicator (mic with slash icon)
- The button should sit at a fixed position alongside the mic button — does not appear/disappear; always present

### Hub Reconnect Toast

When the WebSocket reconnects (not on first connect), the web client briefly shows a "Hub reconnected" toast that dismisses automatically.

**iOS implementation notes:**
- Track whether a previous connection was established before the reconnect
- On reconnect, show a brief system toast or overlay label that auto-dismisses after 2s
- Do not show on first connection

### Per-Session Model Selection

The web client exposes a model picker per session (claude-opus-4-5, claude-sonnet-4-5, etc.) that overrides the global default.

**iOS implementation notes:**
- Add model selector to session view settings (or the session detail area)
- Send model selection via the existing session settings WebSocket message or via `/api/sessions/{id}/model` REST endpoint
- Persist per-session in `sessionPrefs` UserDefaults key alongside voice and speed
