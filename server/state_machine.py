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
      STARTING → IDLE        (first wait WS connects)
      IDLE → PROCESSING      (wait WS disconnects)
      PROCESSING → IDLE      (wait WS connects)
      PROCESSING → COMPACTING (PreCompact hook)
      COMPACTING → IDLE      (wait WS connects)
      COMPACTING → PROCESSING (PreToolUse hook)
      ANY → DEAD             (terminate)
    """

    STARTING = "starting"
    IDLE = "idle"
    PROCESSING = "processing"
    COMPACTING = "compacting"
    DEAD = "dead"
