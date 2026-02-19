# iOS App

Native iPhone companion app for Voice Hub. Connects to the hub over WebSocket and provides the same multi-session voice interface as the browser client.

**Status:** Beta (v0.3.0) - functional but not yet feature-paired with the web client.

## Features

- **Multi-session support** - Spawn, switch between, and terminate voice sessions
- **Voice grid landing** - Same voice card grid as the web client
- **Chat transcript** - User and assistant message bubbles
- **Voice selection** - Pick from all 7 Kokoro voices per session
- **Speed control** - Adjustable TTS playback speed (0.75x-2x)
- **Recording with VAD** - Voice activity detection auto-stops recording on silence
- **Auto-record** - Automatically start recording after assistant finishes speaking
- **Interrupt** - Stop assistant audio playback mid-sentence
- **Thinking indicator** - Pulsing dots while Claude is processing
- **Haptic feedback** - Tactile feedback on record/send/interrupt actions

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
    VoiceChatApp.swift         # SwiftUI app entry point
    VoiceChatViewModel.swift   # WebSocket, audio, state management
    ContentView.swift          # UI (voice grid, chat, controls)
    Assets.xcassets/           # App icon, colors
```

## Known Issues

- **Text wrapping in controls** - Some UI elements (buttons, labels) don't fit properly and wrap or clip on smaller screen widths
- **No debug panel** - Web client's debug tab not yet implemented
- **No audio cues** - Missing the ascending/descending tone feedback the web client has
- **No auto-interrupt** - Voice-based interrupt during playback not implemented
- **No mic mute** - Global mic mute toggle not yet added
- **No chat persistence** - Chat history lost on app restart (web client saves to localStorage)
- **No tab badges** - Background session notifications not visible
- **No background audio buffering** - Unlike the web client, background sessions don't buffer audio for playback on switch
