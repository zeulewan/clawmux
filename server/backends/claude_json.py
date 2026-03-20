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
_compacting: dict[str, bool] = {}       # session currently compacting
_last_usage: dict[str, dict] = {}       # last token usage from result event
_models: dict[str, str] = {}            # session → model string from init

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

        # With --input-format stream-json, the process needs a stdin message
        # before it emits the system/init event. Send startup prompt first.
        startup = "Greet the user as instructed in your CLAUDE.md. Then stop — the hub will deliver messages when they arrive."
        await self._write_stdin(proc, session_name, startup)

        # Now wait for init event
        try:
            await self._wait_for_init(proc, session_name, timeout=30)
        except Exception as e:
            proc.kill()
            _processes.pop(session_name, None)
            raise RuntimeError(f"Claude JSON init failed: {e}")

        # Start background listener (processes all subsequent events)
        listener = asyncio.create_task(self._listen(proc, session_name))
        _listeners[session_name] = listener

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
        _compacting.pop(session_name, None)
        _last_usage.pop(session_name, None)
        _models.pop(session_name, None)
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

    async def monitor_state(
        self,
        session_name: str,
        current_state,
        context_percent: float | None = None,
    ) -> MonitorResult | None:
        """Return compaction state changes based on JSON events."""
        is_compacting = _compacting.get(session_name, False)
        was_compacting = current_state == AgentState.COMPACTING
        if is_compacting and not was_compacting:
            return MonitorResult(
                new_state=AgentState.COMPACTING,
                compaction_event=True,
            )
        elif not is_compacting and was_compacting:
            return MonitorResult(
                new_state=AgentState.PROCESSING,
                compaction_event=False,
            )
        return None

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        proc = _processes.get(session_name)
        if not proc or proc.returncode is not None:
            return RecoveryResult(healthy=False, set_dead=True,
                                  message="Claude JSON subprocess exited")
        return RecoveryResult()

    def get_context_usage(self, session_name: str, session) -> dict | None:
        """Return token usage from last result event (no file I/O needed)."""
        usage = _last_usage.get(session_name)
        if not usage:
            return None
        input_tokens = usage.get("input_tokens", 0)
        cache_creation = usage.get("cache_creation_input_tokens", 0)
        cache_read = usage.get("cache_read_input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        total_context = input_tokens + cache_creation + cache_read
        context_limit = 200000
        model = _models.get(session_name, '') or getattr(session, 'model', '') or getattr(session, 'model_id', '')
        if model and "opus" in model.lower():
            context_limit = 1000000
        # Set model_id on session so the top bar displays it
        if model and hasattr(session, 'model_id') and not session.model_id:
            session.model_id = model
        return {
            "total_context_tokens": total_context,
            "output_tokens": output_tokens,
            "context_limit": context_limit,
            "percent": round(total_context / context_limit * 100, 1),
        }

    # ── Internal helpers ──────────────────────────────────────────────────

    async def _write_stdin(self, proc: asyncio.subprocess.Process, session_name: str, text: str) -> None:
        """Write a user message as JSON to the subprocess stdin.

        Format: {"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}
        """
        msg = json.dumps({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": text}],
            },
        }) + "\n"
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
                    _models[session_name] = model
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

                # --- system events ---
                if event_type == "system":
                    subtype = data.get("subtype", "")
                    if subtype == "compact_boundary":
                        await self._handle_compact_boundary(session_name, hub_port, work_dir)
                    elif subtype == "api_retry":
                        log.info(
                            "[%s] API retry attempt=%s: %s",
                            session_name,
                            data.get("attempt", "?"),
                            data.get("error", ""),
                        )
                    elif subtype == "init":
                        log.debug("[%s] Received init event (already handled)", session_name)

                # --- keep_alive ---
                elif event_type == "keep_alive":
                    pass

                # --- permission request ---
                elif event_type == "control_request":
                    await self._handle_control_request(proc, session_name, data)

                # --- streaming partial events ---
                elif event_type == "stream_event":
                    event = data.get("event", {})
                    await self._handle_stream_event(
                        event, session_name, hub_port, work_dir, send_fn, text_buffer,
                    )

                # --- complete assistant message ---
                elif event_type == "assistant":
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
                    # Cache usage from assistant message
                    usage = msg.get("usage")
                    if usage:
                        _last_usage[session_name] = usage

                # --- tool result ---
                elif event_type == "user":
                    if hub_port and work_dir:
                        await self._post_hook(hub_port, work_dir, "PostToolUse", {
                            "tool_name": "",
                            "tool_input": {},
                        })

                # --- turn complete ---
                elif event_type == "result":
                    is_error = data.get("is_error", False)
                    result_text = data.get("result", "")

                    # Cache usage if present
                    usage = data.get("usage", {})
                    if usage:
                        _last_usage[session_name] = usage

                    if is_error:
                        log.warning(
                            "[%s] Turn ended with error (subtype=%s): %s",
                            session_name,
                            data.get("subtype", "?"),
                            result_text,
                        )
                    else:
                        final_text = result_text or ("".join(text_buffer) if text_buffer else "")
                        if final_text and hub_port:
                            await self._forward_response(hub_port, session_name, final_text)

                    text_buffer.clear()

                    # Signal turn complete regardless of error
                    if hub_port and work_dir:
                        await self._post_hook(hub_port, work_dir, "Stop", {})

                # --- rate limit ---
                elif event_type == "rate_limit_event":
                    pass  # logged elsewhere if needed

                else:
                    log.debug("[%s] Unknown event type: %s", session_name, event_type)

        except asyncio.CancelledError:
            return
        except Exception as e:
            log.error("[%s] Claude JSON listener error: %s", session_name, e, exc_info=True)
        finally:
            if proc.returncode is None:
                log.warning(
                    "[%s] Claude JSON subprocess still running after listener exit",
                    session_name,
                )

    async def _handle_compact_boundary(
        self,
        session_name: str,
        hub_port: int | None,
        work_dir: str | None,
    ) -> None:
        """Handle compact_boundary event — fires twice: start and end."""
        was_compacting = _compacting.get(session_name, False)
        if not was_compacting:
            _compacting[session_name] = True
            log.info("[%s] Compaction started (JSON event)", session_name)
        else:
            _compacting[session_name] = False
            log.info("[%s] Compaction complete (JSON event)", session_name)

    async def _handle_control_request(
        self,
        proc: asyncio.subprocess.Process,
        session_name: str,
        data: dict,
    ) -> None:
        """Respond to permission/control requests from Claude."""
        request_id = data.get("request_id", "")
        request = data.get("request", {})
        subtype = request.get("subtype", "")

        if subtype == "can_use_tool":
            tool_use_id = request.get("tool_use_id", "")
            response = {
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": request_id,
                    "response": {
                        "behavior": "allow",
                        "toolUseID": tool_use_id,
                    },
                },
            }
            msg = json.dumps(response) + "\n"
            try:
                proc.stdin.write(msg.encode())
                await proc.stdin.drain()
                log.debug("[%s] Allowed tool: %s", session_name, request.get("tool_name"))
            except Exception as e:
                log.error("[%s] Failed to send control response: %s", session_name, e)
        else:
            log.warning("[%s] Unhandled control_request subtype: %s", session_name, subtype)

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
