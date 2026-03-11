"""Claude Code backend — manages agents via tmux + Claude Code CLI."""

import asyncio
import logging
import os
import time

# Ensure Homebrew and local bin are in PATH for subprocess calls (macOS).
_EXTRA_PATH = "/opt/homebrew/bin:/usr/local/bin"
_SUBPROCESS_ENV = os.environ.copy()
_SUBPROCESS_ENV["PATH"] = _EXTRA_PATH + ":" + _SUBPROCESS_ENV.get("PATH", "")

from hub_config import AGENT_COLORS, CLAUDE_BASE_COMMAND
from .base import AgentBackend

log = logging.getLogger("hub.backend.claude_code")


class ClaudeCodeBackend(AgentBackend):
    """Runs agents in tmux sessions with Claude Code CLI."""

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
        # Kill stale tmux session with same name
        await self._run(f"tmux kill-session -t {session_name} 2>/dev/null || true")

        # Create tmux session in the work dir
        await self._run(
            f"tmux new-session -d -s {session_name} -x 200 -y 50 -c {work_dir}"
        )

        # Apply agent-colored status bar
        await self.apply_status_bar(session_name, voice_name, voice_id)

        # Set environment variables
        await self._run(
            f'tmux send-keys -t {session_name} '
            f'"unset CLAUDECODE && export CLAWMUX_SESSION_ID={session_id} '
            f'&& export CLAWMUX_WORK_DIR={work_dir} '
            f'&& export CLAWMUX_PORT={hub_port}" Enter'
        )

        # Send a marker so we can detect fresh output from Claude
        short_id = session_id[-6:]
        marker = f"__CLAUDE_INIT_{short_id}__"
        await self._run(f'tmux send-keys -t {session_name} "echo {marker}" Enter')

        # Build Claude command
        model_flag = f" --model {model}" if model != "opus" else ""
        effort_flag = f" --effort {effort}" if effort and model != "haiku" else ""
        startup_prompt = "Greet the user as instructed in your CLAUDE.md. Then stop — the hub will deliver messages when they arrive."
        if resuming:
            claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag}{effort_flag} --resume {claude_session_id} '{startup_prompt}'"
        else:
            claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag}{effort_flag} --session-id {claude_session_id} '{startup_prompt}'"
        await self._run(f'tmux send-keys -t {session_name} "{claude_cmd}" Enter')

        # Wait for Claude to initialize (poll for input prompt AFTER marker)
        await self._wait_for_claude_init(session_name, marker)

    async def terminate(self, session_name: str) -> None:
        try:
            await self._run(f"tmux kill-session -t {session_name}")
        except Exception:
            pass

    async def health_check(self, session_name: str) -> bool:
        proc = await asyncio.create_subprocess_exec(
            "tmux", "has-session", "-t", session_name,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            env=_SUBPROCESS_ENV,
        )
        await proc.wait()
        return proc.returncode == 0

    async def deliver_message(self, session_name: str, text: str) -> None:
        # Shield so both send-keys (text + Enter) complete even if the inject
        # task is cancelled mid-flight during hub shutdown.
        await asyncio.shield(self._tmux_type(session_name, text))

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
        # Kill the entire tmux session
        await self.terminate(session_name)

        # Recreate in the same work dir
        await self._run(
            f"tmux new-session -d -s {session_name} -x 200 -y 50 -c {work_dir}"
        )

        # Apply status bar
        await self.apply_status_bar(session_name, voice_name, voice_id)

        # Set environment
        await self._run(
            f'tmux send-keys -t {session_name} '
            f'"unset CLAUDECODE && export CLAWMUX_SESSION_ID={session_id} '
            f'&& export CLAWMUX_WORK_DIR={work_dir} '
            f'&& export CLAWMUX_PORT={hub_port}" Enter'
        )

        # Send marker and Claude command (always resume on restart)
        short_id = session_id[-6:]
        marker = f"__CLAUDE_INIT_{short_id}__"
        await self._run(f'tmux send-keys -t {session_name} "echo {marker}" Enter')

        model_flag = f" --model {model}" if model != "opus" else ""
        effort_flag = f" --effort {effort}" if effort and model != "haiku" else ""
        startup_prompt = "Greet the user as instructed in your CLAUDE.md. Then stop — the hub will deliver messages when they arrive."
        claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag}{effort_flag} --resume {claude_session_id} '{startup_prompt}'"
        await self._run(f'tmux send-keys -t {session_name} "{claude_cmd}" Enter')

        await self._wait_for_claude_init(session_name, marker)

    async def capture_pane(self, session_name: str) -> str:
        try:
            return await self._run(f"tmux capture-pane -t {session_name} -p")
        except Exception:
            return ""

    # Light-background agents that need black text for contrast
    LIGHT_BG_VOICES = {
        "af_alloy", "am_adam", "am_onyx", "bm_fable", "af_nova", "am_eric", "bf_lily",
        "af_nicole", "bf_alice", "bm_lewis",
    }

    async def apply_status_bar(self, session_name: str, label: str, voice_id: str) -> None:
        color = AGENT_COLORS.get(voice_id)
        if not color:
            return
        fg = "colour16" if voice_id in self.LIGHT_BG_VOICES else "colour231"
        for opt, val in [
            ("status", "on"),
            ("status-style", f"fg={fg},bg={color},bold"),
            ("status-left", f" {label} "),
            ("status-left-style", f"fg={fg},bg={color},bold"),
            ("status-left-length", "20"),
            ("status-right", ""),
            ("status-right-length", "0"),
            ("window-status-current-format", ""),
            ("window-status-format", ""),
        ]:
            await self._run(f"tmux set-option -t {session_name} {opt} '{val}'")

    async def list_live_sessions(self, known_names: set[str]) -> set[str]:
        """Return known session names that have live tmux sessions."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "tmux", "list-sessions", "-F", "#{session_name}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                env=_SUBPROCESS_ENV,
            )
            stdout, _ = await proc.communicate()
            if proc.returncode == 0:
                live = set(stdout.decode().strip().splitlines())
                return live & known_names
        except Exception as e:
            log.error("Error listing tmux sessions: %s", e)
        return set()

    # --- Internal helpers ---

    async def _wait_for_claude_init(self, session_name: str, marker: str) -> None:
        """Poll tmux pane until Claude Code shows its prompt after the marker."""
        start = time.time()
        init_deadline = start + 30
        while time.time() < init_deadline:
            try:
                result = await self._run(f"tmux capture-pane -t {session_name} -p")
                if result and marker in result:
                    after_marker = result.split(marker, 1)[1]
                    if ">" in after_marker or "❯" in after_marker:
                        log.info("[%s] Claude ready (%.1fs)", session_name, time.time() - start)
                        break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            log.warning("[%s] Claude init poll timed out, sending command anyway", session_name)

        # Wait for full initialization (status bar with model name)
        log.info("[%s] Waiting for full initialization", session_name)
        ready_deadline = time.time() + 30
        while time.time() < ready_deadline:
            try:
                result = await self._run(f"tmux capture-pane -t {session_name} -p -e")
                if result and any(kw in result for kw in (
                    "Opus", "Sonnet", "Haiku", "opus", "sonnet", "haiku", "bypass", "plan"
                )):
                    log.info("[%s] Claude Code fully initialized", session_name)
                    break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            log.warning("[%s] Claude Code init poll timed out, injecting anyway", session_name)

        # Small extra delay for input buffer to be ready
        await asyncio.sleep(1)

    async def _tmux_type(self, session_name: str, text: str) -> None:
        """Type text literally into a tmux pane and press Enter."""
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", session_name, "-l", text,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_SUBPROCESS_ENV,
        )
        await proc.communicate()
        # Shield the Enter send — if this coroutine is cancelled after the paste,
        # we must still submit it or the text will sit unsubmitted in the tmux buffer.
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", session_name, "Enter",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_SUBPROCESS_ENV,
        )
        await asyncio.shield(proc.communicate())

    async def _run(self, cmd: str) -> str:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_SUBPROCESS_ENV,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"Command failed ({proc.returncode}): {cmd}\n{stderr.decode()}")
        return stdout.decode()
