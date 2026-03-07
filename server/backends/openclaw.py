"""OpenClaw backend — stub for future OpenClaw agent integration.

OpenClaw agents would communicate via the OpenClaw Gateway API
rather than tmux sessions. Configuration would include:
- gateway_url: URL of the OpenClaw Gateway
- device_id: Paired device identifier
- api_key: Authentication key
"""

from .base import AgentBackend


class OpenClawBackend(AgentBackend):
    """Stub backend for OpenClaw agents. Not yet implemented."""

    async def spawn(self, session_name, work_dir, session_id, hub_port,
                    voice_id, voice_name, claude_session_id, resuming, model):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def terminate(self, session_name):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def health_check(self, session_name):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def deliver_message(self, session_name, text):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def restart(self, session_name, work_dir, session_id, hub_port,
                      voice_id, voice_name, claude_session_id, model):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def capture_pane(self, session_name):
        raise NotImplementedError("OpenClaw backend not yet implemented")

    async def apply_status_bar(self, session_name, label, voice_id):
        raise NotImplementedError("OpenClaw backend not yet implemented")
