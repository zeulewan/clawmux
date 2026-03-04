# Architecture Refactor Brief

*Created: 2026-03-04*

How ClawMux will break apart its monolithic files into maintainable modules.

## The Problem

ClawMux has grown fast. The two core files are now massive monoliths:

- **`static/hub.html`** — 5,571 lines of inline JS, CSS, and HTML in a single file. A syntax error anywhere kills the entire page (the WebSocket never connects, the UI shows "Connecting..." with no useful error).
- **`server/hub.py`** — 2,075 lines handling REST routes, TTS/STT pipeline, WebSocket connections, voice processing, and messaging all mixed together.

Browser state management is the worst pain point. Agent status is tracked through overlapping boolean flags (`awaitingInput`, `processing`, `in_converse`, `userSpokeThisCycle`, `sidebarState`, `toolStatusText`) that interact in unpredictable ways. Race conditions between these flags cause the sidebar to show wrong states, and debugging requires tracing through thousands of lines to find which flag wasn't reset.

Adding any feature — a new sidebar state, a message threading UI, a status indicator — means carefully threading changes through the entire monolith and hoping nothing breaks.

## The Refactor

### Split hub.html into ES Modules

Extract the inline JavaScript into separate files that the browser loads as ES modules:

```
static/
├── hub.html          ← Shell: HTML structure, CSS, module imports
├── js/
│   ├── audio.js      ← TTS playback, STT recording, mic management
│   ├── chat.js       ← Message rendering, threading, scroll behavior
│   ├── sidebar.js    ← Agent cards, status dots, state management
│   └── ws.js         ← WebSocket connection, reconnection, message routing
```

Each module owns one concern. `ws.js` handles the connection and dispatches events. `audio.js` manages the recording and playback pipeline. `chat.js` renders messages. `sidebar.js` tracks agent state. They communicate through a shared event bus, not through global variables.

The HTML file becomes a thin shell: structure, CSS, and `<script type="module">` imports.

### Split hub.py into Python Modules

Break the server into focused modules:

```
server/
├── hub.py            ← App startup, middleware, module wiring
├── routes.py         ← REST API endpoints (/api/sessions, /api/projects, etc.)
├── voice.py          ← TTS/STT pipeline (Kokoro, Whisper, audio processing)
├── websocket.py      ← Browser WS, wait WS, MCP WS handlers
└── messaging.py      ← send_message, inbox files, broker integration
```

`hub.py` becomes the entry point that wires modules together. Each module can be tested and understood independently.

### Replace Booleans with a State Machine

The current approach:

```javascript
// Current: overlapping booleans, easy to get wrong
awaitingInput = false;
processing = true;
in_converse = false;
userSpokeThisCycle = true;
```

The proposed approach:

```javascript
// Proposed: explicit states with clean transitions
const AgentState = {
  IDLE: 'idle',
  LISTENING: 'listening',
  PROCESSING: 'processing',
  SPEAKING: 'speaking',
  CONVERSE: 'converse',
};

function transition(agent, newState) {
  const valid = TRANSITIONS[agent.state];
  if (!valid.includes(newState)) {
    console.warn(`Invalid transition: ${agent.state} → ${newState}`);
    return;
  }
  agent.state = newState;
  updateSidebar(agent);
  updateChat(agent);
}
```

Every agent is always in exactly one state. The sidebar reads from that state directly. Invalid transitions are caught and logged instead of silently creating inconsistencies.

### Remove Legacy Code

After v0.6.0 ships the hook-based messaging system and v0.6.1 removes the converse pipeline:

- Delete the converse WebSocket handler and all related server code
- Remove tmux `send-keys` injection paths
- Clean up deprecated CLI command handlers (already marked deprecated)
- Remove unused boolean flags that only existed for converse flow

## What Changes for Agents

Nothing. The CLI interface (`clawmux send`, `clawmux wait`, `clawmux status`) stays identical. The hub API endpoints stay identical. The refactor is purely internal — agents and the browser UI keep working exactly the same way, just backed by cleaner code.

## What Changes for Development

Everything gets easier:

| Before | After |
|---|---|
| Edit 5,571-line HTML to change a sidebar icon | Edit `sidebar.js` (300 lines) |
| Hunt through 2,075-line Python for a route | Open `routes.py` directly |
| Debug state bugs by tracing boolean flags | Check the state machine transition log |
| One syntax error kills the entire UI | Module error is isolated, other modules keep working |
| `git blame` shows the whole file changed | Changes are scoped to the module that changed |

## Risks

- **Cache busting**: Browsers may cache old JS modules. Need cache-busting hashes or version query params on imports.
- **Import order**: ES modules load asynchronously. Need to ensure the WebSocket connects before other modules try to send messages.
- **Migration window**: During the refactor, the monolith and modules will coexist briefly. Keep the old files as fallback until the split is verified.

## Timeline

This is targeted for v0.7.0, after hook-based messaging (v0.6.0) is stable. The refactor can happen incrementally:

1. **Phase 1**: Extract `ws.js` and `audio.js` (lowest risk, highest value)
2. **Phase 2**: Extract `sidebar.js` with the state machine (fixes the state bugs)
3. **Phase 3**: Extract `chat.js` and clean up the HTML shell
4. **Phase 4**: Split `hub.py` into server modules
5. **Phase 5**: Remove legacy converse code

Each phase is independently deployable and testable.

## Current Status

Not started. Waiting for v0.6.0 hook-based messaging to land first, since that will change the messaging paths significantly and we don't want to refactor code that's about to change.
