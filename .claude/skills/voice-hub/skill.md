# Voice Hub Skill

Voice Hub lets you talk to the user through their browser using speech. The MCP server handles TTS (Kokoro) and STT (Whisper) automatically.

## Available MCP Tools

The `voice-hub` MCP server provides two tools:

- **converse** — Speak a message via TTS and optionally listen for the user's spoken response via STT
  - Parameters: `message` (string), `wait_for_response` (bool, default true), `voice` (string, default "af_sky")
  - Returns: The user's transcribed speech, or a status/error message

- **voice_chat_status** — Check if a browser is connected to the WebSocket
  - Returns: Connection status string

## How to Start a Voice Hub Session

1. Check browser connection with `voice_chat_status`
2. If connected, greet: `converse("Hello! How can I help?")`
3. Process the user's spoken request with full Claude Code tools
4. Respond via `converse()` with a concise spoken summary
5. Loop until user says goodbye, then: `converse("Goodbye!", wait_for_response=false)`

## Voice Response Guidelines

- Keep responses concise — they will be spoken aloud
- No markdown, bullet points, or long lists
- Summarize command output rather than reading it verbatim
- 1-3 short sentences unless the user asks for detail

## Browser URL

The user connects at: `https://workstation.tailee9084.ts.net:3456`

## Logs

Server logs: `tail -f /tmp/voice-hub-mcp.log`
