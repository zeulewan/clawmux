"""Generic CLI backend — stub for future non-Claude agent integration.

Generic CLI agents would run arbitrary CLI commands in tmux sessions
(or subprocess), communicating via stdin/stdout. Configuration would include:
- command: The CLI command to run (e.g. "python agent.py")
- protocol: Message format (json-lines, plain-text)
- env: Additional environment variables
"""

from .base import AgentBackend


class GenericCLIBackend(AgentBackend):
    """Stub backend for generic CLI agents. Not yet implemented."""

    async def spawn(self, session_name, work_dir, session_id, hub_port,
                    voice_id, voice_name, claude_session_id, resuming, model):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def terminate(self, session_name):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def health_check(self, session_name):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def deliver_message(self, session_name, text):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def restart(self, session_name, work_dir, session_id, hub_port,
                      voice_id, voice_name, claude_session_id, model):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def capture_pane(self, session_name):
        raise NotImplementedError("Generic CLI backend not yet implemented")

    async def apply_status_bar(self, session_name, label, voice_id):
        raise NotImplementedError("Generic CLI backend not yet implemented")
