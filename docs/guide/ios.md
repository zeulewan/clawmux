# iOS App

Native iPhone companion app for Voice Hub. Connects to the hub over WebSocket and provides the same multi-session voice interface as the browser client.

**Status:** Beta (v0.5.0) - feature-paired with the web client, background audio and Live Activity support.

## Features

### Voice Sessions
- **Multi-session support** - Spawn, switch between, and terminate voice sessions
- **Voice grid landing** - Same voice card grid as the web client with real-time status
- **Voice card states** - Thinking (orange), speaking (blue), listening (red), ready (green) per session
- **Chat transcript** - User and assistant message bubbles with persistence across restarts
- **Voice selection** - Pick from all 7 Kokoro voices per session (persisted per session)
- **Speed control** - Adjustable TTS playback speed 0.75x-2x (persisted per session)
- **Long-press to terminate** - Context menu on voice cards to kill sessions

### Audio
- **Background audio** - Conversations continue when the app is backgrounded
- **Background recording** - Microphone recording works in background with auto-record
- **Audio pause/resume** - Pauses audio when switching sessions or going home, resumes on return
- **Audio buffering** - Background sessions buffer audio chunks, played sequentially on switch
- **Interrupt** - Stop assistant audio playback mid-sentence
- **Thinking sound** - Double-tick audio cue while Claude is thinking (matches web client)
- **Audio cues** - Listening tone (ascending), processing tone (soft), session ready chime (three-note)

### Recording
- **Recording with VAD** - Voice activity detection auto-stops recording on silence
- **Auto-record** - Automatically start recording after assistant finishes speaking
- **Haptic feedback** - Tactile feedback on record/send/interrupt actions

### Live Activity
- **Dynamic Island** - Shows active session status (thinking/speaking/listening/ready) with colored dot
- **Lock Screen** - "Voice Hub" banner with voice name, status, and last message preview
- **Auto-cleanup** - Stale activities from force-kills are cleaned up on next launch

### UI
- **Modern controls** - Large centered mic button, back button, options menu (no cluttered toggles)
- **Options menu** - Voice, speed, auto-record, and VAD toggles in a dropdown
- **Debug panel** - Hub info, services, sessions, tmux, and log tail
- **Spawning feedback** - Voice card shows "Starting..." with yellow border while session spawns
- **State persistence** - Active page, settings, per-session voice/speed all restored on restart

## Requirements

- iPhone running iOS 17.0+
- Xcode (with iOS platform SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Developer account (free works, apps expire every 7 days)

## Build & Deploy

```bash
cd ios/
xcodegen generate
xcodebuild -project VoiceChat.xcodeproj -scheme VoiceChat \
  -destination 'id=<DEVICE_ID>' \
  -derivedDataPath ./build \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  -quiet build
```

Find your device ID with:

```bash
xcrun devicectl list devices
```

Install to device:

```bash
xcrun devicectl device install app \
  --device <DEVICE_ID> \
  build/Build/Products/Debug-iphoneos/VoiceChat.app
```

Launch remotely:

```bash
xcrun devicectl device process launch \
  --device <DEVICE_ID> \
  com.zeul.voicechat
```

On first install, go to **Settings > General > VPN & Device Management** and trust the developer certificate.

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
  VoiceChat/
    Info.plist                 # App Info.plist (background modes, permissions)
    VoiceChatApp.swift         # SwiftUI app entry point
    VoiceChatViewModel.swift   # WebSocket, audio, state management, Live Activity
    ContentView.swift          # UI (voice grid, chat, controls)
    Assets.xcassets/           # App icon, colors
  VoiceChatShared/
    VoiceChatActivityAttributes.swift  # ActivityKit attributes (shared with widget)
  VoiceChatWidget/
    Info.plist                 # Widget extension Info.plist
    VoiceChatWidgetBundle.swift  # Widget entry point
    VoiceChatLiveActivity.swift  # Dynamic Island + Lock Screen UI
```

## Persistence

All state is saved to UserDefaults and restored on launch:

| Key | Type | Description |
|-----|------|-------------|
| `serverURL` | String | Hub WebSocket URL |
| `activeSessionId` | String? | Which session was open (nil = home) |
| `autoRecord` | Bool | Auto-record after assistant speaks |
| `vadEnabled` | Bool | Voice activity detection enabled |
| `showDebug` | Bool | Debug panel visible |
| `voice-hub-chats` | JSON | Chat messages per session |
| `sessionPrefs` | JSON | Per-session voice and speed settings |

## Background Audio

The app uses `UIBackgroundModes: audio` with a `.playAndRecord` audio session to keep conversations alive in background:

- A near-silent audio loop plays when the app enters background (keeps the audio session and WebSocket alive)
- TTS audio chunks play directly through AVAudioPlayer in background
- Recording works in background when auto-record is enabled
- The silence loop stops automatically when the app returns to foreground

## Known Issues

- **No auto-interrupt** - Voice-based interrupt during playback not implemented
- **No mic mute** - Global mic mute toggle not yet added
