"""Agent state machine — canonical lifecycle states for ClawMux sessions.

See docs: website/docs/agents/reference/state-machine.md
"""

import enum


class AgentState(str, enum.Enum):
    """Canonical agent lifecycle state — single source of truth.

    Two orthogonal axes:
      - state (this enum): where the agent is in its lifecycle
      - activity (str on Session): what the agent is currently doing

    SPEAKING is browser-only (TTS playback is independent of agent state).

    Transitions:
      STARTING → IDLE        (stop hook signals idle via POST /api/agents/{id}/idle)
      IDLE → THINKING        (hub injects message via tmux)
      THINKING → PROCESSING  (PreToolUse hook — first tool call)
      PROCESSING → IDLE      (stop hook signals idle)
      PROCESSING → COMPACTING (PreCompact hook)
      COMPACTING → IDLE      (stop hook signals idle)
      COMPACTING → PROCESSING (PreToolUse hook)
      ANY → DEAD             (terminate)
    """

    STARTING = "starting"
    IDLE = "idle"
    THINKING = "thinking"
    PROCESSING = "processing"
    COMPACTING = "compacting"
    DEAD = "dead"
