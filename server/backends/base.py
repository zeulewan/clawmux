"""Abstract base class for agent backends.

An AgentBackend handles the low-level process management for a single agent:
creating the runtime environment, sending input, checking liveness, and cleanup.
The hub's SessionManager delegates all process operations through this interface.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field


@dataclass
class RecoveryResult:
    """Result from a backend recovery attempt.

    healthy:       True if session is fine, no action needed.
    fixed:         True if a problem was detected and auto-fixed.
    needs_restart: True if the session needs a full restart (hub handles).
    set_dead:      True if the session should be marked DEAD (unrecoverable).
    message:       Human-readable description of what was found/done.
    """
    healthy: bool = True
    fixed: bool = False
    needs_restart: bool = False
    set_dead: bool = False
    message: str = ""


@dataclass
class MonitorResult:
    """Result from periodic backend state monitoring.

    new_state:  AgentState to transition to, or None for no change.
    compaction_event: True = compaction started, False = ended, None = no change.
    stuck_fixed: True if a stuck buffer was detected and auto-fixed.
    """
    new_state: object = None          # AgentState | None (avoids circular import)
    compaction_event: bool | None = None
    stuck_fixed: bool = False


class AgentBackend(ABC):
    """Interface for agent runtime backends (tmux/Claude Code, OpenClaw, etc.)."""

    @abstractmethod
    async def spawn(
        self,
        session_name: str,
        work_dir: str,
        session_id: str,
        hub_port: int,
        voice_id: str,
        voice_name: str,
        claude_session_id: str,
        resuming: bool,
        model: str,
        effort: str = "high",
    ) -> None:
        """Create the agent runtime and start the AI process.

        Args:
            session_name: Unique tmux/process session name.
            work_dir: Absolute path to the agent's working directory.
            session_id: ClawMux session ID (for env vars).
            hub_port: Hub HTTP port (for env vars).
            voice_id: Voice identifier (e.g. "af_sky").
            voice_name: Human-readable name (e.g. "Sky").
            claude_session_id: Conversation UUID (Claude Code resume key).
            resuming: True if resuming an existing conversation.
            model: Model identifier (e.g. opus/sonnet/haiku for Claude, or full model_id for other backends).
            effort: Effort level (low/medium/high). Claude Code only; ignored by other backends.
        """

    @abstractmethod
    async def terminate(self, session_name: str) -> None:
        """Kill the agent runtime process/session.

        Args:
            session_name: The session name passed to spawn().
        """

    @abstractmethod
    async def health_check(self, session_name: str) -> bool:
        """Check if the agent runtime is still alive.

        Args:
            session_name: The session name passed to spawn().

        Returns:
            True if the agent process is running.
        """

    @abstractmethod
    async def deliver_message(self, session_name: str, text: str) -> None:
        """Type a message into the agent's input.

        Used for re-injecting commands (e.g. "clawmux wait") when the agent
        drops out of voice mode.

        Args:
            session_name: The session name passed to spawn().
            text: The message text to type.
        """

    @abstractmethod
    async def restart(
        self,
        session_name: str,
        work_dir: str,
        session_id: str,
        hub_port: int,
        voice_id: str,
        voice_name: str,
        claude_session_id: str,
        model: str,
        effort: str = "high",
    ) -> None:
        """Kill and respawn the agent with a new model/effort, resuming the conversation.

        Args:
            session_name: The session name passed to spawn().
            work_dir: Absolute path to the agent's working directory.
            session_id: ClawMux session ID.
            hub_port: Hub HTTP port.
            voice_id: Voice identifier.
            voice_name: Human-readable name.
            claude_session_id: Claude Code conversation UUID to resume.
            model: New model to use.
        """

    @abstractmethod
    async def capture_pane(self, session_name: str) -> str:
        """Capture the current text content of the agent's terminal.

        Used by the voice watchdog to check agent state.

        Args:
            session_name: The session name passed to spawn().

        Returns:
            The terminal content as a string.
        """

    @abstractmethod
    async def apply_status_bar(self, session_name: str, label: str, voice_id: str) -> None:
        """Apply a colored status bar to the agent's terminal.

        Args:
            session_name: The session name passed to spawn().
            label: Display label (e.g. "Sky").
            voice_id: Voice identifier for color lookup.
        """

    async def interrupt(self, session_name: str) -> bool:
        """Soft-interrupt a running agent.

        Returns True if the interrupt was sent successfully.
        Default implementation sends Escape via tmux (works for Claude Code and Codex).
        """
        return False  # Subclasses override

    async def list_live_sessions(self, known_names: set[str]) -> set[str]:
        """Return the subset of known_names that have live runtime sessions.

        Used by SessionManager to discover orphaned sessions for adoption.
        Default implementation returns empty set (no discovery support).

        Args:
            known_names: Set of session names to check for.

        Returns:
            Set of names that are currently alive.
        """
        return set()

    def restore_session(self, session_name: str, work_dir: str) -> bool:
        """Restore backend-specific state after hub reload.

        Called during session adoption when the hub restarts. Backends that
        maintain in-memory state (e.g. OpenCode port/session maps) override
        this to reload from disk.

        Returns True if state was restored successfully.
        """
        return True  # No-op for backends without persistent state

    def get_context_usage(self, session_name: str, session) -> dict | None:
        """Return token/context usage for this agent, or None if unavailable.

        Returns a dict with: total_context_tokens, output_tokens, context_limit,
        percent. Backends that don't track token usage return None.
        """
        return None

    # --- Backend capability declarations ---

    @property
    def handles_stop_hook_idle(self) -> bool:
        """Whether the Stop hook should transition the agent to IDLE.

        True for backends whose Stop hook reliably signals completion (OpenCode
        bridge plugin, Codex). False for Claude Code, which uses an external
        script (stop-check-inbox.sh) for idle signaling because HTTP Stop hooks
        cannot block the Claude CLI.
        """
        return True

    @property
    def supports_model_restart(self) -> bool:
        """Whether the UI can trigger a model restart for this backend."""
        return False

    @property
    def supports_effort(self) -> bool:
        """Whether this backend supports effort levels (low/medium/high)."""
        return False

    @property
    def idle_delay_after_interrupt(self) -> float:
        """Seconds to wait before forcing IDLE after interrupt.

        Tmux backends may not fire their Stop hook after Escape, so the hub
        needs a fallback timer. Hook-driven backends return 0 (Stop hook
        handles idle transition).
        """
        return 0.0

    def role_update_message(self, role: str) -> str:
        """System message sent to the agent after a role update."""
        return (
            f"Your role has been updated to: {role}. "
            "Your role rules file has been rewritten — "
            "the agent will pick up the changes automatically."
        )

    async def monitor_state(
        self,
        session_name: str,
        current_state,
        context_percent: float | None = None,
    ) -> MonitorResult | None:
        """Poll backend-specific signals and return a MonitorResult, or None.

        Called periodically by the hub's unified monitor loop. Backends that use
        tmux override this to detect compaction, stuck buffers, etc.
        Hook-driven backends (e.g. OpenCode) leave the default no-op.

        Args:
            session_name: tmux session name (or equivalent).
            current_state: Current AgentState of this session.
            context_percent: Context usage percentage (for compaction threshold).

        Returns:
            MonitorResult with state/compaction/stuck info, or None for no action.
        """
        return None

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        """Attempt to recover a broken session.

        Called by the hub's recovery monitor for sessions stuck in PROCESSING
        or STARTING for too long. Each backend checks its own health and tries
        to fix issues autonomously. Returns a RecoveryResult describing the
        outcome.

        Args:
            session_name: The session name passed to spawn().
            work_dir: Absolute path to the agent's working directory.
        """
        return RecoveryResult()  # Default: healthy

    async def clear_stuck_buffer(self, session_name: str) -> None:
        """Clear any text stuck in the agent's input buffer.

        Called once on hub startup for adopted sessions. Tmux backends send
        Enter to flush; others no-op.
        """
