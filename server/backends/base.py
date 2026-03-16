"""Abstract base class for agent backends.

An AgentBackend handles the low-level process management for a single agent:
creating the runtime environment, sending input, checking liveness, and cleanup.
The hub's SessionManager delegates all process operations through this interface.
"""

from abc import ABC, abstractmethod


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
