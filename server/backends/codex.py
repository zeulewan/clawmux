"""Codex CLI backend — manages agents via tmux + Codex CLI.

Codex runs as a TUI in tmux like Claude Code. Message delivery uses tmux
keystroke injection. Key differences from Claude Code:
- CLI: `codex` (at /home/zeul/.local/bin/codex)
- Flags: --no-alt-screen (for tmux), --yolo (bypass approvals + sandbox)
- No effort levels
- Config: AGENTS.md (not CLAUDE.md)
- Idle prompt: `›` with placeholder text
"""

import asyncio
import logging
import time

from .base import AgentBackend
from .claude_code import ClaudeCodeBackend

log = logging.getLogger("hub.backend.codex")

CODEX_COMMAND = "/home/zeul/.local/bin/codex"


class CodexBackend(AgentBackend):
    """Runs agents in tmux sessions with Codex CLI."""

    # Reuse ClaudeCodeBackend for tmux management
    _cc = ClaudeCodeBackend()

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
        # Kill stale tmux session
        await self._cc._run(f"tmux kill-session -t {session_name} 2>/dev/null || true")

        # Create tmux session in work dir
        await self._cc._run(
            f"tmux new-session -d -s {session_name} -x 200 -y 50 -c {work_dir}"
        )

        # Apply colored status bar
        await self._cc.apply_status_bar(session_name, voice_name, voice_id)

        # Set environment variables
        await self._cc._run(
            f'tmux send-keys -t {session_name} '
            f'"export CLAWMUX_SESSION_ID={session_id} '
            f'&& export CLAWMUX_WORK_DIR={work_dir} '
            f'&& export CLAWMUX_PORT={hub_port}" Enter'
        )

        # Send marker for init detection
        short_id = session_id[-6:]
        marker = f"__CODEX_INIT_{short_id}__"
        await self._cc._run(f'tmux send-keys -t {session_name} "echo {marker}" Enter')

        # Build Codex command — only pass model if it's an explicit model_id,
        # not a Claude shorthand (opus/sonnet/haiku) that fell through
        _claude_models = {"opus", "sonnet", "haiku", ""}
        model_flag = f" --model {model}" if model and model not in _claude_models else ""
        startup_prompt = "Greet the user as instructed in your AGENTS.md. Then stop — the hub will deliver messages when they arrive."
        codex_cmd = (
            f"{CODEX_COMMAND} --no-alt-screen --yolo"
            f"{model_flag} '{startup_prompt}'"
        )
        await self._cc._run(f'tmux send-keys -t {session_name} "{codex_cmd}" Enter')

        # Wait for Codex to initialize
        await self._wait_for_codex_init(session_name, marker)

    async def terminate(self, session_name: str) -> None:
        await self._cc.terminate(session_name)

    async def health_check(self, session_name: str) -> bool:
        return await self._cc.health_check(session_name)

    async def deliver_message(self, session_name: str, text: str) -> None:
        # Codex uses tmux injection like Claude Code
        await asyncio.shield(self._cc._tmux_type(session_name, text))

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
        await self.terminate(session_name)
        await self.spawn(
            session_name=session_name,
            work_dir=work_dir,
            session_id=session_id,
            hub_port=hub_port,
            voice_id=voice_id,
            voice_name=voice_name,
            claude_session_id=claude_session_id,
            resuming=False,
            model=model,
            effort=effort,
        )

    async def capture_pane(self, session_name: str) -> str:
        return await self._cc.capture_pane(session_name)

    async def apply_status_bar(self, session_name: str, label: str, voice_id: str) -> None:
        await self._cc.apply_status_bar(session_name, label, voice_id)

    async def list_live_sessions(self, known_names: set[str]) -> set[str]:
        return await self._cc.list_live_sessions(known_names)

    # --- Internal helpers ---

    async def _wait_for_codex_init(self, session_name: str, marker: str) -> None:
        """Poll tmux pane until Codex shows its idle prompt after the marker."""
        start = time.time()
        # Phase 1: wait for marker + prompt character
        deadline = start + 30
        while time.time() < deadline:
            try:
                result = await self._cc._run(f"tmux capture-pane -t {session_name} -p")
                if result and marker in result:
                    after_marker = result.split(marker, 1)[1]
                    if "›" in after_marker or ">" in after_marker:
                        log.info("[%s] Codex prompt detected (%.1fs)", session_name, time.time() - start)
                        break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            log.warning("[%s] Codex init poll timed out", session_name)

        # Phase 2: wait for Codex to be fully initialized (model info banner)
        ready_deadline = time.time() + 30
        while time.time() < ready_deadline:
            try:
                result = await self._cc._run(f"tmux capture-pane -t {session_name} -p")
                if result and "OpenAI Codex" in result:
                    log.info("[%s] Codex fully initialized", session_name)
                    break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            log.warning("[%s] Codex full init poll timed out", session_name)

        # Phase 3: wait for startup prompt to finish processing
        # Codex shows `────` separator and `› Implement` when idle
        idle_deadline = time.time() + 60
        while time.time() < idle_deadline:
            try:
                result = await self._cc._run(f"tmux capture-pane -t {session_name} -p")
                if result:
                    lines = result.strip().splitlines()
                    last_lines = "\n".join(lines[-5:])
                    if "────" in last_lines and "›" in last_lines:
                        log.info("[%s] Codex idle after startup prompt", session_name)
                        break
            except Exception:
                pass
            await asyncio.sleep(2)
        else:
            log.warning("[%s] Codex startup processing timed out", session_name)

        await asyncio.sleep(1)
