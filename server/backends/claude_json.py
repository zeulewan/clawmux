"""Claude Code JSON streaming backend — subprocess with bidirectional JSON pipes.

No tmux. Launches `claude -p --output-format stream-json --verbose` as a
subprocess, sends messages as JSON to stdin, reads structured JSONL events
from stdout. State machine driven entirely by JSON events.
"""

import asyncio
import json
import logging
import os
import signal
import uuid

import hub_config
from hub_config import CLAUDE_BASE_COMMAND
from state_machine import AgentState
from .base import AgentBackend, MonitorResult, RecoveryResult

log = logging.getLogger("hub.backend.claude_json")

# Lazy import to avoid circular dependency
_send_to_browser = None

def _get_send_to_browser():
    global _send_to_browser
    if _send_to_browser is None:
        from hub_state import send_to_browser
        _send_to_browser = send_to_browser
    return _send_to_browser


# Per-session state
_processes: dict[str, asyncio.subprocess.Process] = {}
_listeners: dict[str, asyncio.Task] = {}
_hub_ports: dict[str, int] = {}
_work_dirs: dict[str, str] = {}

_EXTRA_PATH = "/opt/homebrew/bin:/usr/local/bin"
_SUBPROCESS_ENV = os.environ.copy()
_SUBPROCESS_ENV["PATH"] = _EXTRA_PATH + ":" + _SUBPROCESS_ENV.get("PATH", "")


class ClaudeJsonBackend(AgentBackend):
    """Runs Claude Code as a subprocess with JSON stdin/stdout pipes."""

    # ── Capability declarations ───────────────────────────────────────────

    @property
    def handles_stop_hook_idle(self) -> bool:
        return True  # We signal IDLE from JSON result events

    @property
    def sets_idle_on_spawn(self) -> bool:
        return True  # No wait WS — IDLE after spawn

    @property
    def supports_model_restart(self) -> bool:
        return True

    @property
    def supports_effort(self) -> bool:
        return True

    @property
    def idle_delay_after_interrupt(self) -> float:
        return 0.0  # JSON events will signal completion

    def role_update_message(self, role: str) -> str:
        return (
            f"Your role has been updated to: {role}. "
            "Your role rules file has been rewritten — "
            "Claude Code will pick up the changes automatically."
        )

    # ── Lifecycle ─────────────────────────────────────────────────────────

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
        """Launch Claude Code subprocess with JSON streaming."""
        _hub_ports[session_name] = hub_port
        _work_dirs[session_name] = work_dir

        # Build command
        model_flag = f" --model {model}" if model and model != "opus" else ""
        effort_flag = f" --effort {effort}" if effort and model != "haiku" else ""
        session_flag = f" --session-id {conversation_id}"
        if resuming:
            session_flag = f" --resume {conversation_id}"

        cmd = (
            f"{CLAUDE_BASE_COMMAND} -p --output-format stream-json --verbose"
            f" --input-format stream-json --include-partial-messages"
            f"{model_flag}{effort_flag}{session_flag}"
        )

        env = _SUBPROCESS_ENV.copy()
        env["CLAWMUX_SESSION_ID"] = session_id
        env["CLAWMUX_WORK_DIR"] = work_dir
        env["CLAWMUX_PORT"] = str(hub_port)

        try:
            proc = await asyncio.create_subprocess_shell(
                cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                cwd=work_dir,
                env=env,
            )
        except Exception as e:
            log.error("[%s] Failed to start Claude JSON subprocess: %s", session_name, e)
            raise RuntimeError(f"Cannot start Claude Code: {e}")

        _processes[session_name] = proc

        # Wait for init event
        try:
            await self._wait_for_init(proc, session_name, timeout=30)
        except Exception as e:
            proc.kill()
            _processes.pop(session_name, None)
            raise RuntimeError(f"Claude JSON init failed: {e}")

        # Start background listener
        listener = asyncio.create_task(self._listen(proc, session_name))
        _listeners[session_name] = listener

        # Send startup prompt
        startup = "Greet the user as instructed in your CLAUDE.md. Then stop — the hub will deliver messages when they arrive."
        await self._write_stdin(proc, session_name, startup)

        log.info("[%s] Claude JSON subprocess started (pid=%d)", session_name, proc.pid)

    async def terminate(self, session_name: str) -> None:
        listener = _listeners.pop(session_name, None)
        if listener and not listener.done():
            listener.cancel()
        proc = _processes.pop(session_name, None)
        if proc and proc.returncode is None:
            try:
                proc.terminate()
                await asyncio.wait_for(proc.wait(), timeout=5)
            except asyncio.TimeoutError:
                proc.kill()
            except Exception:
                pass
        _hub_ports.pop(session_name, None)
        _work_dirs.pop(session_name, None)
        log.info("[%s] Claude JSON subprocess terminated", session_name)

    async def health_check(self, session_name: str) -> bool:
        proc = _processes.get(session_name)
        return proc is not None and proc.returncode is None

    async def deliver_message(self, session_name: str, text: str) -> None:
        """Write a user message as JSON to stdin."""
        proc = _processes.get(session_name)
        if not proc or proc.returncode is not None:
            log.error("[%s] No live subprocess — cannot deliver message", session_name)
            return
        await self._write_stdin(proc, session_name, text)
        log.info("[%s] Delivered message (%d chars) via stdin", session_name, len(text))

    async def interrupt(self, session_name: str) -> bool:
        """Send SIGINT to the subprocess to interrupt the current turn."""
        proc = _processes.get(session_name)
        if not proc or proc.returncode is not None:
            return False
        try:
            proc.send_signal(signal.SIGINT)
            log.info("[%s] Sent SIGINT to Claude JSON subprocess", session_name)
            return True
        except Exception as e:
            log.error("[%s] Failed to interrupt: %s", session_name, e)
            return False

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
            session_name=session_name, work_dir=work_dir,
            session_id=session_id, hub_port=hub_port,
            voice_id=voice_id, voice_name=voice_name,
            conversation_id=conversation_id,
            resuming=True, model=model, effort=effort,
        )

    async def capture_pane(self, session_name: str) -> str:
        return ""  # No tmux

    async def apply_status_bar(self, session_name: str, label: str, voice_id: str) -> None:
        pass  # No tmux

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        proc = _processes.get(session_name)
        if not proc or proc.returncode is not None:
            return RecoveryResult(healthy=False, set_dead=True,
                                  message="Claude JSON subprocess exited")
        return RecoveryResult()

    def get_context_usage(self, session_name: str, session) -> dict | None:
        """Read token usage from Claude Code's JSONL transcript (same as tmux backend)."""
        from pathlib import Path
        import subprocess as _sp
        conversation_id = getattr(session, 'conversation_id', '')
        if not conversation_id:
            return None
        claude_projects = Path.home() / ".claude" / "projects"
        jsonl_path = None
        if claude_projects.exists():
            for p in claude_projects.iterdir():
                candidate = p / f"{conversation_id}.jsonl"
                if candidate.exists():
                    jsonl_path = candidate
                    break
        if not jsonl_path:
            return None
        try:
            result = _sp.run(
                ["tail", "-n", "50", str(jsonl_path)],
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

    # ── Internal helpers ──────────────────────────────────────────────────

    async def _write_stdin(self, proc: asyncio.subprocess.Process, session_name: str, text: str) -> None:
        """Write a user message as JSON to the subprocess stdin."""
        msg = json.dumps({"type": "user", "content": text}) + "\n"
        try:
            proc.stdin.write(msg.encode())
            await proc.stdin.drain()
        except Exception as e:
            log.error("[%s] Failed to write to stdin: %s", session_name, e)

    async def _wait_for_init(self, proc: asyncio.subprocess.Process, session_name: str, timeout: float = 30) -> None:
        """Wait for the system/init event from Claude Code."""
        deadline = asyncio.get_event_loop().time() + timeout
        while asyncio.get_event_loop().time() < deadline:
            if proc.returncode is not None:
                raise RuntimeError("Subprocess exited during init")
            try:
                line = await asyncio.wait_for(proc.stdout.readline(), timeout=5)
                if not line:
                    continue
                data = json.loads(line.decode())
                if data.get("type") == "system" and data.get("subtype") == "init":
                    model = data.get("model", "")
                    log.info("[%s] Claude JSON init: model=%s", session_name, model)
                    return
            except asyncio.TimeoutError:
                continue
            except json.JSONDecodeError:
                continue
        raise RuntimeError("Timed out waiting for init event")

    async def _listen(self, proc: asyncio.subprocess.Process, session_name: str) -> None:
        """Background task: read JSON events from stdout and forward to hub."""
        hub_port = _hub_ports.get(session_name)
        work_dir = _work_dirs.get(session_name)
        send_fn = _get_send_to_browser()
        # Track current streaming text per message
        current_msg_id = ""
        text_buffer: list[str] = []

        try:
            while proc.returncode is None:
                try:
                    line = await asyncio.wait_for(proc.stdout.readline(), timeout=30)
                except asyncio.TimeoutError:
                    continue
                if not line:
                    if proc.returncode is not None:
                        break
                    continue

                try:
                    data = json.loads(line.decode())
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue

                event_type = data.get("type", "")

                if event_type == "stream_event":
                    event = data.get("event", {})
                    await self._handle_stream_event(
                        event, session_name, hub_port, work_dir, send_fn,
                        text_buffer,
                    )

                elif event_type == "assistant":
                    # Complete assistant message (tool_use or text)
                    msg = data.get("message", {})
                    content = msg.get("content", [])
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_use" and hub_port and work_dir:
                            await self._post_hook(hub_port, work_dir, "PreToolUse", {
                                "tool_name": block.get("name", "tool"),
                                "tool_input": block.get("input", {}),
                            })
                        elif block.get("type") == "text":
                            text = block.get("text", "")
                            if text:
                                text_buffer.clear()
                                text_buffer.append(text)

                elif event_type == "user":
                    # Tool result
                    tool_result = data.get("tool_use_result", {})
                    if hub_port and work_dir:
                        await self._post_hook(hub_port, work_dir, "PostToolUse", {
                            "tool_name": "",
                            "tool_input": {},
                        })

                elif event_type == "result":
                    # Turn complete — forward any buffered text and signal idle
                    result_text = data.get("result", "")
                    final_text = result_text or ("".join(text_buffer) if text_buffer else "")
                    text_buffer.clear()
                    if final_text and hub_port:
                        await self._forward_response(hub_port, session_name, final_text)
                    if hub_port and work_dir:
                        await self._post_hook(hub_port, work_dir, "Stop", {})

        except asyncio.CancelledError:
            return
        except Exception as e:
            log.error("[%s] Claude JSON listener error: %s", session_name, e)
        finally:
            if proc.returncode is None:
                log.warning("[%s] Claude JSON subprocess still running after listener exit", session_name)

    async def _handle_stream_event(
        self, event: dict, session_name: str, hub_port: int | None,
        work_dir: str | None, send_fn, text_buffer: list[str],
    ) -> None:
        """Handle a stream_event (partial message chunk)."""
        event_type = event.get("type", "")

        if event_type == "content_block_start":
            block = event.get("content_block", {})
            if block.get("type") == "text":
                text_buffer.clear()

        elif event_type == "content_block_delta":
            delta = event.get("delta", {})
            delta_type = delta.get("type", "")
            if delta_type == "text_delta":
                text = delta.get("text", "")
                if text:
                    text_buffer.append(text)
                    # Push streaming text to browser
                    accumulated = "".join(text_buffer)
                    try:
                        await send_fn({
                            "type": "assistant_text",
                            "session_id": session_name,
                            "text": accumulated,
                            "msg_id": f"cj-{session_name}-stream",
                            "fire_and_forget": True,
                            "streaming": True,
                        })
                    except Exception:
                        pass

    async def _forward_response(self, hub_port: int, session_name: str, text: str) -> None:
        """Forward complete response to the hub via speak endpoint."""
        import httpx
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"http://127.0.0.1:{hub_port}/api/messages/speak",
                    json={"sender": session_name, "message": text},
                )
        except Exception as e:
            log.error("[%s] Failed to forward response: %s", session_name, e)

    async def _post_hook(self, hub_port: int, work_dir: str, event: str, extra: dict) -> None:
        """POST a hook event to the local hub."""
        import httpx
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"http://127.0.0.1:{hub_port}/api/hooks/tool-status",
                    json={"hook_event_name": event, "cwd": work_dir, **extra},
                )
        except Exception as e:
            log.debug("[%s] Hook POST failed: %s", work_dir, e)
