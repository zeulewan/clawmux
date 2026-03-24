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

# Lazy imports to avoid circular dependency (hub_state imports backends.claude_code)
_hub_refs = {}

def _get_hub():
    """Lazy-load hub_state references for direct state updates."""
    if not _hub_refs:
        from hub_state import send_to_browser, session_mgr, _session_status_msg, _save_activity
        _hub_refs["send"] = send_to_browser
        _hub_refs["mgr"] = session_mgr
        _hub_refs["status_msg"] = _session_status_msg
        _hub_refs["save_activity"] = _save_activity
    return _hub_refs


# Per-session state
_processes: dict[str, asyncio.subprocess.Process] = {}
_listeners: dict[str, asyncio.Task] = {}
_hub_ports: dict[str, int] = {}
_work_dirs: dict[str, str] = {}
_compacting: dict[str, bool] = {}       # session currently compacting
_last_usage: dict[str, dict] = {}       # last token usage from result event
_models: dict[str, str] = {}            # session → model string from init
_active_tools: dict[str, dict] = {}    # session → {tool_use_id: {name, input}} for result association
_permission_modes: dict[str, str] = {} # session → permission mode
_pending_permissions: dict[str, asyncio.Future] = {}  # request_id → Future for browser response

VALID_PERMISSION_MODES = {"bypassPermissions", "auto", "acceptEdits", "plan", "default", "dontAsk"}

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

        # Determine permission mode
        perm_mode = _permission_modes.get(session_name, "bypassPermissions")
        _permission_modes[session_name] = perm_mode

        # Build command — use base claude without --dangerously-skip-permissions
        # when a non-bypass permission mode is active
        model_flag = f" --model {model}" if model and model != "opus" else ""
        effort_flag = f" --effort {effort}" if effort and model != "haiku" else ""
        session_flag = f" --session-id {conversation_id}"
        if resuming:
            session_flag = f" --resume {conversation_id}"

        if perm_mode == "bypassPermissions":
            base_cmd = CLAUDE_BASE_COMMAND  # includes --dangerously-skip-permissions
        else:
            base_cmd = "claude --permission-mode " + perm_mode

        cmd = (
            f"{base_cmd} -p --output-format stream-json --verbose"
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
        _active_tools.pop(session_name, None)
        _permission_modes.pop(session_name, None)
        # Cancel any pending permission requests
        for req_id, fut in list(_pending_permissions.items()):
            if req_id.startswith(session_name + ":"):
                fut.cancel()
                _pending_permissions.pop(req_id, None)
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
        """Background task: read JSON events from stdout, update state directly.

        No HTTP hook roundtrip — state changes are applied immediately via
        hub_state imports (session_mgr, send_to_browser, _save_activity).
        """
        hub_port = _hub_ports.get(session_name)
        hub = _get_hub()
        send_fn = hub["send"]
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
                session = hub["mgr"].sessions.get(session_name)
                if not session:
                    continue

                # --- system events ---
                if event_type == "system":
                    subtype = data.get("subtype", "")
                    if subtype == "compact_boundary":
                        was = _compacting.get(session_name, False)
                        _compacting[session_name] = not was
                        if not was:
                            session.set_state(AgentState.COMPACTING)
                            session.activity = "Compacting"
                            await hub["save_activity"](session, "Compacting")
                            await send_fn({
                                "type": "compaction_status",
                                "session_id": session_name,
                                "compacting": True,
                            })
                            log.info("[%s] Compaction started", session_name)
                        else:
                            session.set_state(AgentState.PROCESSING)
                            await send_fn({
                                "type": "compaction_status",
                                "session_id": session_name,
                                "compacting": False,
                            })
                            log.info("[%s] Compaction complete", session_name)
                        await send_fn(hub["status_msg"](session))
                    elif subtype == "api_retry":
                        log.info("[%s] API retry attempt=%s: %s",
                                 session_name, data.get("attempt", "?"), data.get("error", ""))
                    elif subtype == "init":
                        pass  # already handled in _wait_for_init

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
                        event, session_name, hub_port, None, send_fn, text_buffer,
                    )

                # --- complete assistant message ---
                elif event_type == "assistant":
                    msg = data.get("message", {})
                    content = msg.get("content", [])
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        block_type = block.get("type", "")
                        if block_type == "tool_use":
                            tool_id = block.get("id", "")
                            tool_name = block.get("name", "tool")
                            tool_input = block.get("input", {})
                            # Track for result association
                            tools = _active_tools.setdefault(session_name, {})
                            tools[tool_id] = {"name": tool_name, "input": tool_input}
                            # Direct state update
                            if session.state == AgentState.IDLE:
                                session.set_state(AgentState.PROCESSING)
                            session.tool_name = tool_name
                            session.tool_input = tool_input
                            session.activity = self._tool_activity(tool_name, tool_input)
                            await hub["save_activity"](session, session.activity)
                            await send_fn(hub["status_msg"](session))
                            await send_fn({
                                "type": "structured_event",
                                "session_id": session_name,
                                "event_type": "tool_use",
                                "tool_name": tool_name,
                                "tool_id": tool_id,
                                "data": tool_input,
                            })
                        elif block_type == "text":
                            text = block.get("text", "")
                            if text:
                                text_buffer.clear()
                                text_buffer.append(text)
                        elif block_type == "thinking":
                            # Extended thinking block — forward for collapsible display
                            thinking_text = block.get("thinking", "")
                            if thinking_text:
                                await send_fn({
                                    "type": "structured_event",
                                    "session_id": session_name,
                                    "event_type": "thinking",
                                    "data": {"text": thinking_text[:500]},
                                })
                    # Cache usage
                    usage = msg.get("usage")
                    if usage:
                        _last_usage[session_name] = usage

                # --- tool result ---
                elif event_type == "user":
                    msg = data.get("message", {})
                    content = msg.get("content", [])
                    # Extract tool results and associate with original tool calls
                    tool_results = []
                    for block in (content if isinstance(content, list) else []):
                        if not isinstance(block, dict):
                            continue
                        if block.get("type") == "tool_result":
                            use_id = block.get("tool_use_id", "")
                            result_content = block.get("content", "")
                            if isinstance(result_content, list):
                                result_content = "".join(
                                    b.get("text", "") for b in result_content
                                    if isinstance(b, dict) and b.get("type") == "text"
                                )
                            # Look up original tool call
                            tools = _active_tools.get(session_name, {})
                            original = tools.pop(use_id, {})
                            tool_results.append({
                                "tool_use_id": use_id,
                                "tool_name": original.get("name", ""),
                                "tool_input": original.get("input", {}),
                                "content": str(result_content)[:500],
                                "is_error": block.get("is_error", False),
                            })
                    session.activity = ""
                    session.tool_name = ""
                    session.tool_input = {}
                    session.set_state(AgentState.PROCESSING)
                    await hub["save_activity"](session, "Processing")
                    await send_fn(hub["status_msg"](session))
                    # Send enriched tool_result event with original call info
                    for tr in tool_results:
                        await send_fn({
                            "type": "structured_event",
                            "session_id": session_name,
                            "event_type": "tool_result",
                            "tool_name": tr["tool_name"],
                            "tool_id": tr["tool_use_id"],
                            "data": {
                                "content": tr["content"],
                                "input": tr["tool_input"],
                                "is_error": tr["is_error"],
                            },
                        })
                    if not tool_results:
                        await send_fn({
                            "type": "structured_event",
                            "session_id": session_name,
                            "event_type": "tool_result",
                        })

                # --- turn complete ---
                elif event_type == "result":
                    is_error = data.get("is_error", False)
                    result_text = data.get("result", "")

                    usage = data.get("usage", {})
                    if usage:
                        _last_usage[session_name] = usage

                    if is_error:
                        log.warning("[%s] Turn ended with error (subtype=%s): %s",
                                    session_name, data.get("subtype", "?"), result_text)
                    else:
                        final_text = result_text or ("".join(text_buffer) if text_buffer else "")
                        if final_text and hub_port:
                            await self._forward_response(hub_port, session_name, final_text)

                    text_buffer.clear()

                    # Direct IDLE transition
                    session.set_state(AgentState.IDLE)
                    session.activity = ""
                    session.tool_name = ""
                    session.tool_input = {}
                    await hub["save_activity"](session, "Idle")
                    await send_fn({"session_id": session_name, "type": "listening", "state": "idle"})
                    await send_fn(hub["status_msg"](session))

                # --- rate limit ---
                elif event_type == "rate_limit_event":
                    pass

                else:
                    log.debug("[%s] Unknown event type: %s", session_name, event_type)

        except asyncio.CancelledError:
            return
        except Exception as e:
            log.error("[%s] Claude JSON listener error: %s", session_name, e, exc_info=True)
        finally:
            if proc.returncode is None:
                log.warning("[%s] Subprocess still running after listener exit", session_name)

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
        """Respond to permission/control requests from Claude.

        In bypass mode: auto-allow everything.
        In other modes: forward to browser, wait for response.
        """
        request_id = data.get("request_id", "")
        request = data.get("request", {})
        subtype = request.get("subtype", "")
        perm_mode = _permission_modes.get(session_name, "bypassPermissions")

        if subtype != "can_use_tool":
            log.warning("[%s] Unhandled control_request subtype: %s", session_name, subtype)
            return

        tool_use_id = request.get("tool_use_id", "")
        tool_name = request.get("tool_name", "")

        if perm_mode == "bypassPermissions":
            # Auto-allow in bypass mode
            await self._send_control_response(proc, session_name, request_id, tool_use_id, "allow")
            return

        # Forward to browser and wait for response
        hub = _get_hub()
        send_fn = hub["send"]
        await send_fn({
            "type": "structured_event",
            "session_id": session_name,
            "event_type": "permission_request",
            "data": {
                "request_id": request_id,
                "tool_name": tool_name,
                "tool_use_id": tool_use_id,
                "input": request.get("input", {}),
                "title": request.get("title", ""),
                "description": request.get("description", ""),
                "display_name": request.get("display_name", tool_name),
            },
        })

        # Create a Future and wait for the browser to resolve it
        perm_key = f"{session_name}:{request_id}"
        future = asyncio.get_event_loop().create_future()
        _pending_permissions[perm_key] = future

        try:
            response = await asyncio.wait_for(future, timeout=300)
            behavior = response.get("behavior", "deny")
            message = response.get("message", "")
        except asyncio.TimeoutError:
            behavior = "deny"
            message = "Permission request timed out (5 minutes)"
            log.warning("[%s] Permission request %s timed out", session_name, request_id)
        except asyncio.CancelledError:
            behavior = "deny"
            message = "Permission request cancelled"
        finally:
            _pending_permissions.pop(perm_key, None)

        if behavior == "allow":
            await self._send_control_response(proc, session_name, request_id, tool_use_id, "allow")
        else:
            await self._send_control_response(
                proc, session_name, request_id, tool_use_id, "deny", message,
            )

    async def _send_control_response(
        self, proc, session_name: str, request_id: str,
        tool_use_id: str, behavior: str, message: str = "",
    ) -> None:
        """Write a control_response to the subprocess stdin."""
        if behavior == "allow":
            response_data = {"behavior": "allow", "toolUseID": tool_use_id}
        else:
            response_data = {"behavior": "deny", "message": message or "Denied by user"}

        response = {
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": response_data,
            },
        }
        msg = json.dumps(response) + "\n"
        try:
            proc.stdin.write(msg.encode())
            await proc.stdin.drain()
            log.info("[%s] Permission %s: %s (%s)", session_name, behavior, request_id, tool_use_id)
        except Exception as e:
            log.error("[%s] Failed to send control response: %s", session_name, e)

    @staticmethod
    def resolve_permission(session_name: str, request_id: str, allow: bool, message: str = "") -> bool:
        """Resolve a pending permission request from the browser.

        Returns True if the request was found and resolved.
        """
        perm_key = f"{session_name}:{request_id}"
        future = _pending_permissions.get(perm_key)
        if not future or future.done():
            return False
        future.set_result({
            "behavior": "allow" if allow else "deny",
            "message": message,
        })
        return True

    @staticmethod
    def set_permission_mode(session_name: str, mode: str) -> bool:
        """Set the permission mode for a session. Requires restart to take effect."""
        if mode not in VALID_PERMISSION_MODES:
            return False
        _permission_modes[session_name] = mode
        return True

    @staticmethod
    def get_permission_mode(session_name: str) -> str:
        """Get the current permission mode for a session."""
        return _permission_modes.get(session_name, "bypassPermissions")

    async def _handle_stream_event(
        self, event: dict, session_name: str, hub_port: int | None,
        work_dir: str | None, send_fn, text_buffer: list[str],
    ) -> None:
        """Handle a stream_event (partial message chunk)."""
        event_type = event.get("type", "")

        if event_type == "content_block_start":
            block = event.get("content_block", {})
            block_type = block.get("type", "")
            if block_type == "text":
                text_buffer.clear()
            elif block_type == "thinking":
                # Thinking block started — signal frontend
                try:
                    await send_fn({
                        "type": "structured_event",
                        "session_id": session_name,
                        "event_type": "thinking",
                        "data": {"status": "start"},
                    })
                except Exception:
                    pass

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

    @staticmethod
    def _tool_activity(tool_name: str, tool_input: dict) -> str:
        """Generate human-readable activity text for a tool call."""
        from pathlib import Path
        if tool_name == "Read":
            path = tool_input.get("file_path", "")
            return f"Reading {Path(path).name}" if path else "Reading file"
        if tool_name == "Write":
            path = tool_input.get("file_path", "")
            return f"Writing {Path(path).name}" if path else "Writing file"
        if tool_name == "Edit":
            path = tool_input.get("file_path", "")
            return f"Editing {Path(path).name}" if path else "Editing file"
        if tool_name == "Bash":
            desc = tool_input.get("description", "")
            if desc:
                return f"Running {desc}"
            cmd = tool_input.get("command", "").strip()
            preview = cmd[:60] + ("…" if len(cmd) > 60 else "")
            return f"Running {preview}" if preview else "Running command"
        if tool_name == "Grep":
            pattern = tool_input.get("pattern", "")
            return f"Searching for {pattern}" if pattern else "Searching"
        return tool_name

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
