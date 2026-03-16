"""Claude Code backend — manages agents via tmux + Claude Code CLI."""

import asyncio
import json
import logging
import os
import subprocess
import time

# Ensure Homebrew and local bin are in PATH for subprocess calls (macOS).
_EXTRA_PATH = "/opt/homebrew/bin:/usr/local/bin"
_SUBPROCESS_ENV = os.environ.copy()
_SUBPROCESS_ENV["PATH"] = _EXTRA_PATH + ":" + _SUBPROCESS_ENV.get("PATH", "")

from hub_config import AGENT_COLORS, CLAUDE_BASE_COMMAND
from state_machine import AgentState
from .base import AgentBackend, MonitorResult, RecoveryResult

log = logging.getLogger("hub.backend.claude_code")


class ClaudeCodeBackend(AgentBackend):
    """Runs agents in tmux sessions with Claude Code CLI."""

    def __init__(self) -> None:
        self._stuck_counts: dict[str, int] = {}  # session_name → consecutive count

    # --- Capability overrides ---

    @property
    def handles_stop_hook_idle(self) -> bool:
        return False  # Uses stop-check-inbox.sh, not HTTP Stop hook

    @property
    def supports_model_restart(self) -> bool:
        return True

    @property
    def supports_effort(self) -> bool:
        return True

    @property
    def idle_delay_after_interrupt(self) -> float:
        return 3.0  # Stop hook may not fire after Escape

    def role_update_message(self, role: str) -> str:
        return (
            f"Your role has been updated to: {role}. "
            "Your role rules file has been rewritten — "
            "Claude Code will pick up the changes automatically."
        )

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

    async def interrupt(self, session_name: str) -> bool:
        """Send Escape to the tmux pane to soft-interrupt the agent."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "tmux", "send-keys", "-t", session_name, "Escape",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                env=_SUBPROCESS_ENV,
            )
            await proc.wait()
            return proc.returncode == 0
        except Exception:
            return False

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

    def get_context_usage(self, session_name: str, session) -> dict | None:
        """Read token usage from Claude Code's JSONL transcript."""
        from pathlib import Path
        claude_session_id = getattr(session, 'claude_session_id', '')
        if not claude_session_id:
            return None
        claude_projects = Path.home() / ".claude" / "projects"
        jsonl_path = None
        if claude_projects.exists():
            for p in claude_projects.iterdir():
                candidate = p / f"{claude_session_id}.jsonl"
                if candidate.exists():
                    jsonl_path = candidate
                    break
        if not jsonl_path:
            return None
        try:
            result = subprocess.run(
                ["tail", "-50", str(jsonl_path)],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode != 0:
                return None
            last_usage = None
            last_model = None
            for line in result.stdout.strip().split("\n"):
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    usage = None
                    model = None
                    if d.get("type") == "assistant" and "message" in d:
                        msg = d["message"] if isinstance(d["message"], dict) else {}
                        usage = msg.get("usage") or d.get("usage")
                        model = msg.get("model")
                    elif d.get("type") == "assistant" and "usage" in d:
                        usage = d["usage"]
                    if usage:
                        last_usage = usage
                    if model:
                        last_model = model
                except (json.JSONDecodeError, KeyError):
                    continue
            if not last_usage:
                return None
            input_tokens = last_usage.get("input_tokens", 0)
            cache_creation = last_usage.get("cache_creation_input_tokens", 0)
            cache_read = last_usage.get("cache_read_input_tokens", 0)
            output_tokens = last_usage.get("output_tokens", 0)
            total_context = input_tokens + cache_creation + cache_read
            context_limit = 200000
            if last_model and "opus" in last_model:
                context_limit = 1000000
            elif getattr(session, 'model', '') == "opus":
                context_limit = 1000000
            return {
                "total_context_tokens": total_context,
                "output_tokens": output_tokens,
                "context_limit": context_limit,
                "percent": round(total_context / context_limit * 100, 1),
            }
        except Exception as e:
            log.warning("Error reading context usage for %s: %s", session_name, e)
            return None

    async def monitor_state(
        self,
        session_name: str,
        current_state,
        context_percent: float | None = None,
    ) -> MonitorResult | None:
        """Poll tmux pane for compaction and stuck buffer signals.

        Compaction: detected when "compacting" (not "compacted") appears in pane.
        Only checked when context_percent >= 80 or already COMPACTING.

        Stuck buffer: detected when tmux shows "[Pasted text" or content after ❯.
        Two consecutive detections required before auto-fix (send Enter).
        """
        if current_state == AgentState.DEAD:
            self._stuck_counts.pop(session_name, None)
            return None

        # Single pane capture for both checks
        try:
            pane = await self._run(f"tmux capture-pane -t {session_name} -p")
        except Exception:
            return None

        result = MonitorResult()

        # --- Compaction detection ---
        should_check_compaction = (
            current_state == AgentState.COMPACTING
            or (context_percent is not None and context_percent >= 80)
        )
        if should_check_compaction:
            lines = pane.strip().splitlines()
            is_compacting = False
            for line in reversed(lines):
                ll = line.lower().strip()
                if "compacting" in ll and "compacted" not in ll:
                    is_compacting = True
                    break
                if "compacted" in ll:
                    break

            was_compacting = current_state == AgentState.COMPACTING
            if is_compacting and not was_compacting:
                result.new_state = AgentState.COMPACTING
                result.compaction_event = True
                return result
            elif not is_compacting and was_compacting:
                result.new_state = AgentState.PROCESSING
                result.compaction_event = False
                return result

        # --- Stuck buffer detection ---
        if current_state == AgentState.COMPACTING:
            self._stuck_counts.pop(session_name, None)
            return None

        is_processing = current_state == AgentState.PROCESSING
        last_lines = pane.strip().splitlines()[-10:]
        snippet = "\n".join(last_lines)

        if is_processing:
            is_stuck = "[Pasted text" in snippet or "[Typed text" in snippet
        else:
            is_stuck = (
                "[Pasted text" in snippet
                or "[Typed text" in snippet
                or any(line.startswith('❯') and len(line.rstrip()) > 1 for line in last_lines)
            )

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
                        env=_SUBPROCESS_ENV,
                    )
                    await proc.communicate()
                    self._stuck_counts[session_name] = 0
                    result.stuck_fixed = True
                    log.info("[%s] Stuck buffer cleared", session_name)
                except Exception as exc:
                    log.error("[%s] Failed to clear stuck buffer: %s", session_name, exc)
        else:
            self._stuck_counts.pop(session_name, None)

        return result if result.stuck_fixed else None

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        """Check tmux session health, fix stuck buffers, report dead sessions."""
        alive = await self.health_check(session_name)
        if not alive:
            return RecoveryResult(healthy=False, set_dead=True,
                                  message="tmux session dead")

        # Aggressive stuck buffer check — immediate fix (no 2-strike threshold)
        try:
            pane = await self.capture_pane(session_name)
            last_lines = pane.strip().splitlines()[-10:]
            snippet = "\n".join(last_lines)
            if "[Pasted text" in snippet or "[Typed text" in snippet:
                await self.clear_stuck_buffer(session_name)
                return RecoveryResult(healthy=False, fixed=True,
                                      message="cleared stuck buffer")
        except Exception:
            pass

        return RecoveryResult()

    async def clear_stuck_buffer(self, session_name: str) -> None:
        """Send Enter to flush any text stuck in tmux input buffer."""
        try:
            proc = await asyncio.create_subprocess_exec(
                "tmux", "send-keys", "-t", session_name, "Enter",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
                env=_SUBPROCESS_ENV,
            )
            await proc.communicate()
        except Exception as exc:
            log.debug("[%s] clear_stuck_buffer failed: %s", session_name, exc)

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
        """Type text literally into a tmux pane and press Enter.

        Callers should shield this coroutine if they need atomicity (text + Enter
        must both land even if the outer task is cancelled).
        """
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", session_name, "-l", text,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_SUBPROCESS_ENV,
        )
        await proc.communicate()
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", session_name, "Enter",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=_SUBPROCESS_ENV,
        )
        await proc.communicate()

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
