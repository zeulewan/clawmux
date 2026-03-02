# Conversation Dynamics

How messages flow between you, the browser, the hub, and the AI agent — and who controls what at each step.

## The Players

| Component | Role |
|-----------|------|
| **Browser** | Your interface. Records your voice, plays agent audio, shows status. |
| **Hub** | The traffic controller (port 3460). Routes audio between browser, STT/TTS services, and agents. |
| **Whisper** | Speech-to-text. Runs on your GPU. Turns your voice into text. |
| **Kokoro** | Text-to-speech. Runs on your GPU. Turns agent text into voice. |
| **Agent** | A Claude Code session running in tmux. Does the actual work. |
| **MCP Server** | Bridge between the agent and the hub. Exposes `converse()` as a tool the agent can call. |

## The Converse Cycle

Everything revolves around the `converse()` tool. The agent calls it to speak and (optionally) listen. Here's one full cycle:

The agent calls `converse("Hello!", wait_for_response=true)`. The MCP server forwards this to the hub, which shows a thinking indicator in the browser, synthesizes the text via Kokoro TTS, and sends the MP3 to the browser to play. Once playback finishes, the hub signals the browser to start recording. The user's audio is sent back to the hub, transcribed by Whisper STT, and the resulting text is returned to the agent.

## Who Controls What

This is the key insight: **the agent drives the conversation, not the browser or the hub.**

The hub doesn't decide when to listen or when to speak. It waits for the agent to call `converse()`. The browser doesn't decide when to record. It waits for the hub to send a `listening` signal. The flow is always:

1. **Agent decides to speak** → calls `converse()`
2. **Hub orchestrates** → TTS, audio delivery, STT
3. **Result returns to agent** → agent decides what to do next

### The Gap Between Calls

After `converse()` returns the user's transcribed text, the agent goes off to do work — reading files, running commands, writing code. During this time:

- The agent is **not** calling `converse()`
- The hub has **no visibility** into what the agent is doing
- The browser shows whatever the last status was

This gap is where status indicators can become inaccurate. The hub sent "done" after the last converse cycle completed, so the browser may show "Ready" — even though the agent is actively working.

## Message Types

The hub communicates with the browser via WebSocket messages:

| Message | Direction | Meaning |
|---------|-----------|---------|
| `thinking` | Hub → Browser | Agent received input, processing |
| `assistant_text` | Hub → Browser | Agent's text response (shown in chat) |
| `status` | Hub → Browser | Status bar update ("Speaking...", "Transcribing...") |
| `audio` | Hub → Browser | MP3 audio to play |
| `listening` | Hub → Browser | Ready for user to record |
| `done` | Hub → Browser | Converse cycle complete |
| `session_ended` | Hub → Browser | Agent said goodbye, session closing |
| `playback_done` | Browser → Hub | Audio finished playing |
| `audio` | Browser → Hub | User's recorded audio |
| `text` | Browser → Hub | User's typed message |

## The `wait_for_response` Parameter

The agent controls whether it wants to hear back:

- **`wait_for_response=true`** (default): Full cycle. Agent speaks, then listens for user response. Returns the user's transcribed text.
- **`wait_for_response=false`**: Fire-and-forget. Agent speaks but doesn't listen. The hub plays the audio and moves on. Used for status updates, acknowledgments, or goodbye messages.

## The `goodbye` Parameter

When the agent is done with the conversation:

- **`goodbye=true`**: After the audio plays, the hub sends `session_ended` to the browser. The browser auto-closes the session after 3 seconds.
- **`goodbye=false`** (default): Normal operation. Session stays open.

## State Timeline

Here's what happens during a typical interaction, showing what each component is doing:

```
Time    Agent               Hub                 Browser
─────   ─────               ───                 ───────
  0     calls converse()    receives request     idle
  1     waiting...          sends "thinking"     shows "Thinking..."
  2     waiting...          calls Kokoro TTS     shows "Thinking..."
  3     waiting...          sends audio          plays audio
  4     waiting...          waits for playback   playing...
  5     waiting...          receives done        sends playback_done
  6     waiting...          sends "listening"    shows "Listening..."
  7     waiting...          waiting for audio    recording...
  8     waiting...          receives audio       shows "Processing..."
  9     waiting...          calls Whisper STT    shows "Processing..."
 10     gets text back      sends "done"         shows "Ready"
 11     reading files...    idle                 shows "Ready" ← gap
 12     running commands... idle                 shows "Ready" ← gap
 13     writing code...     idle                 shows "Ready" ← gap
 14     calls converse()    receives request     cycle repeats
```

Notice the gap from time 11–13: the agent is working, but the browser shows "Ready" because the hub has no way to know the agent is still active.

## Design Implications

The agent-driven model means:

- **The agent must always call `converse()` to keep the conversation going.** If the agent stops calling `converse()`, the user has no way to communicate.
- **Status accuracy depends on the converse cycle.** Between cycles, the hub can only guess at the agent's state.
- **Audio queuing exists but is hidden.** If the user records audio while the agent is busy, it gets queued in the hub and delivered on the next `converse(wait_for_response=true)` call. But the browser doesn't show this queue.
- **The agent could report its own status.** A future `report_status()` tool could let the agent tell the hub what it's doing between converse cycles, making the status indicators accurate.
