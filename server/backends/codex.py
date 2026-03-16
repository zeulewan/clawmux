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

from state_machine import AgentState
from .base import AgentBackend, MonitorResult, RecoveryResult
from .claude_code import ClaudeCodeBackend

log = logging.getLogger("hub.backend.codex")

CODEX_COMMAND = "/home/zeul/.local/bin/codex"


class CodexBackend(AgentBackend):
    """Runs agents in tmux sessions with Codex CLI."""

    # Reuse ClaudeCodeBackend for tmux management
    _cc = ClaudeCodeBackend()

    def __init__(self) -> None:
        self._stuck_counts: dict[str, int] = {}  # session_name → consecutive count

    @property
    def idle_delay_after_interrupt(self) -> float:
        return 3.0  # tmux Escape may not trigger Stop hook

    @property
    def supports_effort(self) -> bool:
        return True  # Codex supports reasoning_effort: low/medium/high/default

    async def spawn(
        self,
        session_name: str,
        work_dir: str,
        session_id: str,
        hub_port: int,
        voice_id: str,
        voice_name: str,
        conversation_id: str,
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
        # Codex reasoning effort: -c reasoning_effort=<level>
        _valid_codex_efforts = {"low", "medium", "high"}
        effort_flag = f' -c reasoning_effort="{effort}"' if effort in _valid_codex_efforts else ""
        startup_prompt = "Greet the user as instructed in your AGENTS.md. Then stop — the hub will deliver messages when they arrive."
        codex_cmd = (
            f"{CODEX_COMMAND} --no-alt-screen --yolo"
            f"{model_flag}{effort_flag} '{startup_prompt}'"
        )
        await self._cc._run(f'tmux send-keys -t {session_name} "{codex_cmd}" Enter')

        # Wait for Codex to initialize
        await self._wait_for_codex_init(session_name, marker)

    async def terminate(self, session_name: str) -> None:
        await self._cc.terminate(session_name)

    async def health_check(self, session_name: str) -> bool:
        return await self._cc.health_check(session_name)

    async def interrupt(self, session_name: str) -> bool:
        return await self._cc.interrupt(session_name)

    async def deliver_message(self, session_name: str, text: str) -> None:
        """Type text into Codex TUI and submit with double Enter.

        Codex's TUI requires two Enter presses: the first confirms the input
        text, the second submits it for processing.
        """
        async def _codex_type(session: str, msg: str) -> None:
            proc = await asyncio.create_subprocess_exec(
                "tmux", "send-keys", "-t", session, "-l", msg,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            await asyncio.sleep(0.3)
            proc = await asyncio.create_subprocess_exec(
                "tmux", "send-keys", "-t", session, "Enter",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            await asyncio.sleep(0.3)
            proc = await asyncio.create_subprocess_exec(
                "tmux", "send-keys", "-t", session, "Enter",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
        await asyncio.shield(_codex_type(session_name, text))

    async def restart(
        self,
        session_name: str,
        work_dir: str,
        session_id: str,
        hub_port: int,
        voice_id: str,
        voice_name: str,
        conversation_id: str,
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
            conversation_id=conversation_id,
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

    async def monitor_state(
        self,
        session_name: str,
        current_state,
        context_percent: float | None = None,
    ) -> MonitorResult | None:
        """Poll tmux pane for stuck buffer signals.

        Codex has no compaction — only stuck buffer detection.
        Same two-consecutive-detection threshold as Claude Code.
        """
        if current_state in (AgentState.DEAD, AgentState.COMPACTING):
            self._stuck_counts.pop(session_name, None)
            return None

        try:
            pane = await self._cc.capture_pane(session_name)
        except Exception:
            return None

        is_processing = current_state == AgentState.PROCESSING
        last_lines = pane.strip().splitlines()[-10:]
        snippet = "\n".join(last_lines)

        if is_processing:
            is_stuck = "[Pasted text" in snippet or "[Typed text" in snippet
        else:
            is_stuck = "[Pasted text" in snippet or "[Typed text" in snippet

        if is_stuck:
            count = self._stuck_counts.get(session_name, 0) + 1
            self._stuck_counts[session_name] = count
            if count >= 2:
                log.warning("[%s] STUCK BUFFER detected (seen %dx) — sending Enter", session_name, count)
                try:
                    proc = await asyncio.create_subprocess_exec(
                        "tmux", "send-keys", "-t", session_name, "Enter",
                        stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL,
                    )
                    await proc.communicate()
                    self._stuck_counts[session_name] = 0
                    log.info("[%s] Stuck buffer cleared", session_name)
                    return MonitorResult(stuck_fixed=True)
                except Exception as exc:
                    log.error("[%s] Failed to clear stuck buffer: %s", session_name, exc)
        else:
            self._stuck_counts.pop(session_name, None)

        return None

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        """Check tmux session health, fix stuck buffers, report dead sessions."""
        alive = await self._cc.health_check(session_name)
        if not alive:
            return RecoveryResult(healthy=False, set_dead=True,
                                  message="tmux session dead")

        try:
            pane = await self._cc.capture_pane(session_name)
            last_lines = pane.strip().splitlines()[-10:]
            snippet = "\n".join(last_lines)
            if "[Pasted text" in snippet or "[Typed text" in snippet:
                await self.clear_stuck_buffer(session_name)
                return RecoveryResult(healthy=False, fixed=True,
                                      message="cleared stuck buffer")
        except Exception:
            pass

        return RecoveryResult()

    def get_context_usage(self, session_name: str, session) -> dict | None:
        """Parse model, effort, and context from Codex's tmux status line.

        Status line format: "gpt-5.4 default · 85% left · /path/to/work"
        We extract: model name, reasoning effort, and percent-left.
        """
        import subprocess as _sp
        import re
        try:
            result = _sp.run(
                ["tmux", "capture-pane", "-t", session_name, "-p"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode != 0:
                return None
            pane = result.stdout.strip()
            if not pane:
                return None
            lines = pane.splitlines()
            last_line = lines[-1].strip() if lines else ""
            # Match: "model-name effort · N% left · /path"
            m = re.match(r'^(\S+)\s+(\S+)\s+·\s+(\d+)%\s+left\s+·', last_line)
            if not m:
                return None
            model_name = m.group(1)
            effort_level = m.group(2)
            pct_left = int(m.group(3))
            pct_used = 100 - pct_left
            # Update session fields from parsed values
            if model_name and hasattr(session, 'model_id'):
                session.model_id = model_name
            if effort_level and hasattr(session, 'effort'):
                session.effort = effort_level
            return {
                "total_context_tokens": 0,
                "output_tokens": 0,
                "context_limit": 0,
                "percent": pct_used,
            }
        except Exception as e:
            log.warning("Error reading Codex context for %s: %s", session_name, e)
            return None

    async def clear_stuck_buffer(self, session_name: str) -> None:
        """Send Enter to flush any text stuck in tmux input buffer."""
        await self._cc.clear_stuck_buffer(session_name)

    # --- Internal helpers ---

    async def _wait_for_codex_init(self, session_name: str, marker: str) -> None:
        """Poll tmux pane until Codex is fully idle after processing the startup prompt.

        The reliable ready signal is the status line at the bottom of the pane:
        `gpt-5.4 default · 100% left · /path` — this only appears when Codex is
        idle and ready for input.
        """
        start = time.time()
        deadline = start + 90  # startup prompt processing can take a while
        while time.time() < deadline:
            try:
                result = await self._cc._run(f"tmux capture-pane -t {session_name} -p")
                if result and marker in result:
                    # Check for the status line (present only when idle)
                    lines = result.strip().splitlines()
                    last_line = lines[-1].strip() if lines else ""
                    # Status line format: "model default · N% left · /path"
                    if "% left" in last_line:
                        log.info("[%s] Codex ready (%.1fs)", session_name, time.time() - start)
                        return
            except Exception:
                pass
            await asyncio.sleep(2)
        log.warning("[%s] Codex init poll timed out after %.0fs", session_name, time.time() - start)
