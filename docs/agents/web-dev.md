# Web Development

You are building features for the Voice Hub browser UI (`static/hub.html`).

## Docs You Must Keep Updated

When you add or change a feature, update these docs to match:

| Document | What to update |
|----------|---------------|
| [UI Behavior](ui-behavior.md) | Any new states, buttons, toggles, audio behaviors, or state transitions |
| [WebSocket Protocol](protocol.md) | Any new or changed WebSocket messages, REST endpoints, or session fields |
| [Agent Reference](agent-reference.md) | New state variables, config changes, file map changes |
| [Roadmap](../roadmap/v0.3.0.md) | Check off completed features, move items between versions |

Other clients (iOS app, future desktop app) are built from these docs. If you change behavior without updating the docs, those clients will be out of sync.

## Key Files

```
static/hub.html              # The entire browser UI (HTML + CSS + JS in one file)
hub.py                        # Hub server — REST API, WebSocket handlers, TTS/STT
hub_config.py                 # Constants — ports, timeouts, voice list, service URLs
session_manager.py            # Session lifecycle — tmux spawn/kill, temp dirs
hub_mcp_server.py             # Thin MCP server running inside each Claude session
```

## Conventions

- The browser UI is a **single HTML file** with embedded CSS and JS. No build step, no bundling.
- All session state lives in the `sessions` Map keyed by `session_id`.
- `setStatus(text, sessionId)` updates both the DOM and `s.statusText` and triggers voice grid re-render. Always use it instead of writing to `statusEl` directly.
- `renderVoiceGridIfActive()` re-renders the home page grid only if the home tab is showing. Call it after any state change that affects voice card display.
- `updateMicUI()` derives the main button state from `currentAudio`, `recording`, etc. Call it after changing any of those.
- Toggles default to: Auto Record off, Auto End on, Auto Interrupt off. Toggle states are not persisted across page loads.
- Chat messages are persisted to `localStorage`. Session list comes from the hub on WebSocket connect.

## Testing

After making changes:

1. Reload the hub (`python hub.py`) if you changed server-side code
2. Hard-refresh the browser (`Ctrl+Shift+R`) for client-side changes
3. Verify on the home page (voice cards update correctly)
4. Verify in a session (buttons, audio, recording, thinking indicators)
5. Verify tab switching (audio pause/resume, background buffering)
6. Verify the debug panel still loads
