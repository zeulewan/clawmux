"""OpenClaw backend — connects to an external OpenClaw Gateway via WebSocket.

Unlike other backends, OpenClaw agents are always-on in the Gateway.
No tmux, no process spawning. We connect as an operator client and
deliver messages via the Gateway's chat.send method.

Responses stream back as event:agent WebSocket events and are forwarded
to the hub via POST to the local hook endpoint.
"""

import asyncio
import base64
import hashlib
import json
import logging
import os
import time
import uuid
from pathlib import Path

import httpx
import websockets
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    Encoding, NoEncryption, PrivateFormat, PublicFormat,
)

import hub_config
from .base import AgentBackend, MonitorResult, RecoveryResult

# Lazy import to avoid circular dependency (hub_state imports backends.claude_code)
_send_to_browser = None

def _get_send_to_browser():
    global _send_to_browser
    if _send_to_browser is None:
        from hub_state import send_to_browser
        _send_to_browser = send_to_browser
    return _send_to_browser

log = logging.getLogger("hub.backend.openclaw")

_DEVICE_IDENTITY_PATH = hub_config.DATA_DIR / "openclaw-device.json"
_device_identity: dict | None = None  # cached after first load


def _b64url_encode(data: bytes) -> str:
    """Base64url encode without padding (RFC 4648)."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _load_or_create_device_identity() -> dict:
    """Load or generate a persistent Ed25519 device identity.

    Returns dict with: deviceId, publicKeyRaw (bytes), privateKey (Ed25519PrivateKey obj),
    publicKeyB64url (str for wire format).
    """
    global _device_identity
    if _device_identity:
        return _device_identity

    if _DEVICE_IDENTITY_PATH.exists():
        try:
            stored = json.loads(_DEVICE_IDENTITY_PATH.read_text())
            priv_bytes = base64.b64decode(stored["privateKeyB64"])
            priv_key = Ed25519PrivateKey.from_private_bytes(priv_bytes)
            pub_raw = base64.b64decode(stored["publicKeyRawB64"])
            device_id = hashlib.sha256(pub_raw).hexdigest()
            _device_identity = {
                "deviceId": device_id,
                "publicKeyRaw": pub_raw,
                "publicKeyB64url": _b64url_encode(pub_raw),
                "privateKey": priv_key,
            }
            log.info("Loaded OpenClaw device identity: %s", device_id[:16])
            return _device_identity
        except Exception as e:
            log.warning("Failed to load device identity, regenerating: %s", e)

    # Generate new keypair
    priv_key = Ed25519PrivateKey.generate()
    pub_key = priv_key.public_key()
    # Raw 32-byte public key
    pub_raw = pub_key.public_bytes(Encoding.Raw, PublicFormat.Raw)
    # Raw 32-byte private key seed
    priv_raw = priv_key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    device_id = hashlib.sha256(pub_raw).hexdigest()

    # Persist
    _DEVICE_IDENTITY_PATH.parent.mkdir(parents=True, exist_ok=True)
    stored = {
        "version": 1,
        "deviceId": device_id,
        "publicKeyRawB64": base64.b64encode(pub_raw).decode(),
        "privateKeyB64": base64.b64encode(priv_raw).decode(),
    }
    _DEVICE_IDENTITY_PATH.write_text(json.dumps(stored, indent=2) + "\n")
    try:
        os.chmod(_DEVICE_IDENTITY_PATH, 0o600)
    except Exception:
        pass

    _device_identity = {
        "deviceId": device_id,
        "publicKeyRaw": pub_raw,
        "publicKeyB64url": _b64url_encode(pub_raw),
        "privateKey": priv_key,
    }
    log.info("Generated new OpenClaw device identity: %s", device_id[:16])
    return _device_identity


def _clawmux_session_key(agent_id: str = "main") -> str:
    """Build a ClawMux-specific sessionKey for an OpenClaw agent."""
    return f"agent:{agent_id}:clawmux:direct:hub"


# Per-session state
_connections: dict[str, object] = {}     # session_name → websocket connection
_listeners: dict[str, asyncio.Task] = {} # session_name → listener task
_hub_ports: dict[str, int] = {}          # session_name → hub port (for hook POSTs)
_work_dirs: dict[str, str] = {}          # session_name → work_dir (for session lookup)
_agent_ids: dict[str, str] = {}          # session_name → OpenClaw agent ID
_session_keys: dict[str, str] = {}       # session_name → resolved sessionKey


class OpenClawBackend(AgentBackend):
    """Connects to OpenClaw Gateway via WebSocket for message delivery.

    Phase 1: basic connection, handshake, deliver_message, response forwarding.
    No tmux, no pane capture, no stuck buffer detection.
    """

    # ── Agent discovery ────────────────────────────────────────────────────

    async def list_agents(self) -> list[dict]:
        """Query the Gateway for available OpenClaw agents.

        Connects temporarily, completes handshake, sends agents.list request,
        returns list of dicts with id, name, identity fields.
        """
        gateway_url = hub_config.OPENCLAW_GATEWAY_URL
        token = hub_config.OPENCLAW_GATEWAY_TOKEN
        try:
            ws = await websockets.connect(
                gateway_url,
                additional_headers={"User-Agent": "clawmux/discovery"},
                ping_interval=15,
                close_timeout=5,
            )
        except Exception as e:
            log.error("Failed to connect to Gateway for agent discovery: %s", e)
            return []

        try:
            await self._handshake(ws, "__discovery__", token)
            req_id = f"clawmux-agents-{uuid.uuid4().hex[:8]}"
            await ws.send(json.dumps({
                "type": "req",
                "id": req_id,
                "method": "agents.list",
                "params": {},
            }))
            resp_raw = await asyncio.wait_for(ws.recv(), timeout=10)
            resp = json.loads(resp_raw)
            # May get intervening events before the response — drain until we get our res
            while resp.get("type") != "res" or resp.get("id") != req_id:
                resp_raw = await asyncio.wait_for(ws.recv(), timeout=10)
                resp = json.loads(resp_raw)
            if not resp.get("ok"):
                log.warning("agents.list failed: %s", resp.get("error", {}))
                return []
            payload = resp.get("payload", {})
            agents = payload.get("agents", []) if isinstance(payload, dict) else []
            if not isinstance(agents, list):
                return []
            # Enrich with display names from IDENTITY.md if available
            workspace = hub_config.OPENCLAW_WORKSPACE
            for agent in agents:
                if not agent.get("name") and not agent.get("identity", {}).get("name"):
                    identity_path = workspace / "IDENTITY.md"
                    if identity_path.exists():
                        try:
                            for line in identity_path.read_text().splitlines():
                                if line.strip().startswith("- **Name:**"):
                                    name = line.split("**Name:**", 1)[1].strip()
                                    if name:
                                        agent.setdefault("identity", {})["name"] = name
                                        agent["name"] = name
                                    break
                        except Exception:
                            pass
            return agents
        except Exception as e:
            log.error("Agent discovery failed: %s", e)
            return []
        finally:
            await ws.close()

    async def fetch_history(self, session_name: str, limit: int = 30) -> list[dict]:
        """Fetch chat history by reading the session JSONL file directly.

        Returns messages in ClawMux history format: [{role, text, ts, id}, ...].
        Reads from disk to avoid conflicting with the _listen() WS recv loop.
        """
        return self._read_session_jsonl(session_name, limit)

    def _read_session_jsonl(self, session_name: str, limit: int = 30) -> list[dict]:
        """Fallback: read history directly from the OpenClaw session JSONL file."""
        from datetime import datetime
        agent_id = _agent_ids.get(session_name, "main")
        sk = _session_keys.get(session_name, "")
        sessions_path = Path.home() / ".openclaw" / "agents" / agent_id / "sessions" / "sessions.json"
        try:
            sessions = json.loads(sessions_path.read_text())
            session_data = sessions.get(sk, {})
            jsonl_path = session_data.get("sessionFile", "")
            if not jsonl_path or not Path(jsonl_path).exists():
                return []
            # Read from the end — enough lines to get limit user/assistant text messages.
            # Typical ratio: ~60% of "message" records have displayable text.
            import subprocess as _sp
            result = _sp.run(
                ["tail", "-n", str(limit * 10), jsonl_path],
                capture_output=True, text=True, timeout=5,
            )
            messages = []
            for line in result.stdout.strip().splitlines():
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("type") != "message":
                    continue
                msg = record.get("message", {})
                role = msg.get("role", "")
                if role not in ("user", "assistant"):
                    continue
                # Extract text from content array, skipping toolCall-only messages
                text = self._extract_text(msg)
                if not text:
                    continue
                # Filter out Telegram delivery metadata and system context
                text = self._strip_delivery_metadata(text)
                if not text:
                    continue
                ts_str = record.get("timestamp", "")
                try:
                    ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
                except Exception:
                    ts = 0
                messages.append({
                    "role": role,
                    "text": text,
                    "ts": ts,
                    "id": record.get("id", ""),
                })
            return messages[-limit:]
        except Exception as e:
            log.warning("[%s] Failed to read session JSONL: %s", session_name, e)
            return []

    # ── Capability declarations ───────────────────────────────────────────

    @property
    def handles_stop_hook_idle(self) -> bool:
        return True  # We signal IDLE when agent stops responding

    @property
    def sets_idle_on_spawn(self) -> bool:
        return True  # No wait WS — set IDLE immediately after connect

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
        agent_id: str = "main",
        session_key: str = "",
    ) -> None:
        """Connect to Gateway WS and start listening for agent events.

        agent_id: OpenClaw agent ID (e.g. "main", "speedy"). Defaults to "main".
        session_key: Gateway sessionKey to join. Auto-detected from sessions.json if empty.
        """
        gateway_url = hub_config.OPENCLAW_GATEWAY_URL
        token = hub_config.OPENCLAW_GATEWAY_TOKEN

        resolved_key = session_key or _clawmux_session_key(agent_id)
        _hub_ports[session_name] = hub_port
        _work_dirs[session_name] = work_dir
        _agent_ids[session_name] = agent_id
        _session_keys[session_name] = resolved_key
        log.info("[%s] Using sessionKey: %s", session_name, resolved_key)

        try:
            ws = await websockets.connect(
                gateway_url,
                additional_headers={"User-Agent": f"clawmux/{session_name}"},
                ping_interval=15,
                ping_timeout=10,
                close_timeout=5,
            )
        except Exception as e:
            log.error("[%s] Failed to connect to Gateway at %s: %s", session_name, gateway_url, e)
            raise RuntimeError(f"Cannot connect to OpenClaw Gateway: {e}")

        _connections[session_name] = ws

        # Complete the handshake
        try:
            await self._handshake(ws, session_name, token)
        except Exception as e:
            await ws.close()
            _connections.pop(session_name, None)
            log.error("[%s] Gateway handshake failed: %s", session_name, e)
            raise RuntimeError(f"OpenClaw handshake failed: {e}")

        # Write env vars so OpenClaw's exec commands can use `clawmux send`
        self._write_clawmux_env(session_name, session_id, hub_port, work_dir)

        # Start background listener for agent events
        listener = asyncio.create_task(self._listen(ws, session_name))
        _listeners[session_name] = listener

        log.info("[%s] Connected to OpenClaw Gateway at %s", session_name, gateway_url)

    async def terminate(self, session_name: str) -> None:
        """Disconnect from Gateway WS."""
        listener = _listeners.pop(session_name, None)
        if listener and not listener.done():
            listener.cancel()
        ws = _connections.pop(session_name, None)
        if ws:
            try:
                await ws.close()
            except Exception:
                pass
        _hub_ports.pop(session_name, None)
        _work_dirs.pop(session_name, None)
        _agent_ids.pop(session_name, None)
        _session_keys.pop(session_name, None)
        log.info("[%s] Disconnected from OpenClaw Gateway", session_name)

    async def health_check(self, session_name: str) -> bool:
        """OpenClaw agents are always-on in the Gateway.

        Return True even if WS is disconnected — the agent is still alive
        in the Gateway, we just need to reconnect. The recovery monitor
        handles reconnection via recover().
        """
        return True

    async def deliver_message(self, session_name: str, text: str) -> None:
        """Send a message to the OpenClaw agent via Gateway chat.send."""
        ws = _connections.get(session_name)
        if not ws:
            log.error("[%s] No Gateway connection — cannot deliver message", session_name)
            return

        sk = _session_keys.get(session_name, "agent:main:main")
        req_id = f"clawmux-{uuid.uuid4().hex[:8]}"
        request = {
            "type": "req",
            "id": req_id,
            "method": "chat.send",
            "params": {
                "sessionKey": sk,
                "message": text,
                "idempotencyKey": req_id,
            },
        }

        try:
            await ws.send(json.dumps(request))
            log.info("[%s] Sent chat.send (id=%s, %d chars)", session_name, req_id, len(text))
        except Exception as e:
            log.error("[%s] Failed to send message via Gateway: %s", session_name, e)

        # Signal PROCESSING to the hub
        hub_port = _hub_ports.get(session_name)
        work_dir = _work_dirs.get(session_name)
        if hub_port and work_dir:
            await self._post_hook(hub_port, work_dir, "PreToolUse", {
                "tool_name": "OpenClaw",
                "tool_input": {"message": text[:100]},
            })

    async def interrupt(self, session_name: str) -> bool:
        """Abort the active agent run via Gateway."""
        ws = _connections.get(session_name)
        if not ws:
            return False
        sk = _session_keys.get(session_name, "agent:main:main")
        req_id = f"clawmux-abort-{uuid.uuid4().hex[:8]}"
        try:
            await ws.send(json.dumps({
                "type": "req",
                "id": req_id,
                "method": "chat.abort",
                "params": {"sessionKey": sk},
            }))
            log.info("[%s] Sent chat.abort to Gateway", session_name)
            return True
        except Exception as e:
            log.error("[%s] Failed to abort: %s", session_name, e)
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
            session_name=session_name,
            work_dir=work_dir,
            session_id=session_id,
            hub_port=hub_port,
            voice_id=voice_id,
            voice_name=voice_name,
            conversation_id=conversation_id,
            resuming=True,
            model=model,
            effort=effort,
        )

    async def capture_pane(self, session_name: str) -> str:
        return ""  # No tmux pane

    async def apply_status_bar(self, session_name: str, label: str, voice_id: str) -> None:
        pass  # No tmux

    async def recover(self, session_name: str, work_dir: str) -> RecoveryResult:
        """Check if WS is still connected."""
        ws = _connections.get(session_name)
        if not ws or not ws.open:
            return RecoveryResult(healthy=False, needs_restart=True,
                                  message="Gateway WebSocket disconnected")
        return RecoveryResult()

    # ── Internal helpers ──────────────────────────────────────────────────

    @staticmethod
    def _write_clawmux_env(session_name: str, session_id: str, hub_port: int, work_dir: str) -> None:
        """Write ClawMux env vars into the OpenClaw workspace .env file.

        OpenClaw loads ~/.openclaw/workspace/.env via dotenv on startup and
        inherits these into exec commands. This lets the agent use `clawmux send`
        without manual setup.

        Also writes a global fallback at ~/.openclaw/.env (loaded when CWD
        isn't the workspace).
        """
        env_lines = [
            f"CLAWMUX_SESSION_ID={session_id}",
            f"CLAWMUX_PORT={hub_port}",
            f"CLAWMUX_WORK_DIR={work_dir}",
        ]
        env_content = "\n".join(env_lines) + "\n"

        for env_path in (
            hub_config.OPENCLAW_WORKSPACE / ".env",
            Path.home() / ".openclaw" / ".env",
        ):
            try:
                # Merge: preserve existing vars, update ClawMux ones
                existing = {}
                if env_path.exists():
                    for line in env_path.read_text().splitlines():
                        line = line.strip()
                        if line and not line.startswith("#") and "=" in line:
                            key = line.split("=", 1)[0]
                            if not key.startswith("CLAWMUX_"):
                                existing[key] = line
                merged = list(existing.values()) + env_lines
                env_path.parent.mkdir(parents=True, exist_ok=True)
                env_path.write_text("\n".join(merged) + "\n")
                log.info("[%s] Wrote ClawMux env to %s", session_name, env_path)
            except Exception as e:
                log.warning("[%s] Failed to write env to %s: %s", session_name, env_path, e)

    async def _handshake(self, ws, session_name: str, token: str) -> None:
        """Complete the Gateway connect handshake with Ed25519 device signing."""
        identity = _load_or_create_device_identity()

        # Wait for connect.challenge event
        challenge_raw = await asyncio.wait_for(ws.recv(), timeout=10)
        challenge = json.loads(challenge_raw)
        if challenge.get("event") != "connect.challenge":
            raise RuntimeError(f"Expected connect.challenge, got: {challenge.get('event', challenge.get('type'))}")

        nonce = challenge.get("payload", {}).get("nonce", "")

        # Build v2 signing payload:
        # v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
        # client.id and client.mode must be from the Gateway's enum allowlist
        client_id = "cli"
        client_mode = "cli"
        role = "operator"
        scopes = ["operator.read", "operator.write"]
        signed_at_ms = int(time.time() * 1000)

        payload_parts = [
            "v2",
            identity["deviceId"],
            client_id,
            client_mode,
            role,
            ",".join(scopes),
            str(signed_at_ms),
            token or "",
            nonce,
        ]
        payload_str = "|".join(payload_parts)

        # Sign with Ed25519 private key
        signature_bytes = identity["privateKey"].sign(payload_str.encode("utf-8"))
        signature_b64url = _b64url_encode(signature_bytes)

        connect_id = f"clawmux-connect-{uuid.uuid4().hex[:8]}"
        connect_req = {
            "type": "req",
            "id": connect_id,
            "method": "connect",
            "params": {
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": {
                    "id": client_id,
                    "version": "0.1.0",
                    "platform": "linux",
                    "mode": client_mode,
                    "instanceId": session_name,
                },
                "role": role,
                "scopes": scopes,
                "caps": [],
                "commands": [],
                "permissions": {},
                "auth": {"token": token} if token else {},
                "locale": "en-US",
                "userAgent": f"clawmux/{session_name}",
                "device": {
                    "id": identity["deviceId"],
                    "publicKey": identity["publicKeyB64url"],
                    "signature": signature_b64url,
                    "signedAt": signed_at_ms,
                    "nonce": nonce,
                },
            },
        }
        await ws.send(json.dumps(connect_req))

        # Wait for response
        resp_raw = await asyncio.wait_for(ws.recv(), timeout=10)
        resp = json.loads(resp_raw)
        if resp.get("type") != "res" or not resp.get("ok"):
            error = resp.get("error", {})
            details = error.get("details", {})
            raise RuntimeError(
                f"Gateway rejected connect: {error.get('message', resp)} "
                f"(code={details.get('code', '?')})"
            )

        # Persist device token if returned
        resp_auth = resp.get("payload", {}).get("auth", {})
        device_token = resp_auth.get("deviceToken")
        if device_token:
            log.info("[%s] Received device token from Gateway", session_name)

        log.info("[%s] Gateway handshake complete (protocol=%s)",
                 session_name, resp.get("payload", {}).get("protocol", "?"))

    async def _listen(self, ws, session_name: str) -> None:
        """Background task: receive Gateway events and forward to hub.

        Gateway emits two event types for agent responses:
        - "chat" events with state: delta|final|aborted|error
          (delta = streaming text chunk, final = done, message field has text)
        - "agent" events with stream field for tool calls/results/thinking
        """
        hub_port = _hub_ports.get(session_name)
        work_dir = _work_dirs.get(session_name)
        our_session_key = _session_keys.get(session_name, "agent:main:main")
        response_buffer: list[str] = []
        # Stable msg_id per run — so the browser can replace the streaming message
        current_run_id: str = ""
        current_msg_id: str = ""

        try:
            async for raw in ws:
                try:
                    msg = json.loads(raw)
                except (json.JSONDecodeError, TypeError):
                    continue

                msg_type = msg.get("type")
                event_name = msg.get("event", "")

                if msg_type == "event" and event_name == "chat":
                    payload = msg.get("payload", {})
                    if payload.get("sessionKey") != our_session_key:
                        continue
                    state = payload.get("state", "")
                    run_id = payload.get("runId", "")

                    # New run — generate a stable msg_id for this response
                    if run_id and run_id != current_run_id:
                        current_run_id = run_id
                        current_msg_id = f"oc-{uuid.uuid4().hex[:8]}"
                        response_buffer.clear()

                    if state == "delta":
                        # Each delta contains the FULL accumulated text so far
                        text = self._extract_text(payload.get("message"))
                        if text:
                            response_buffer.clear()
                            response_buffer.append(text)
                            # Push streaming update to browser
                            if hub_port:
                                await self._send_to_hub(hub_port, {
                                    "type": "assistant_text",
                                    "session_id": session_name,
                                    "text": text,
                                    "msg_id": current_msg_id,
                                    "fire_and_forget": True,
                                    "streaming": True,
                                })

                    elif state == "final":
                        final_text = self._extract_text(payload.get("message"))
                        if final_text:
                            full_text = final_text
                        elif response_buffer:
                            full_text = response_buffer[0]
                        else:
                            full_text = ""
                        response_buffer.clear()
                        if full_text and hub_port:
                            # Send final complete message (replaces streaming version)
                            await self._forward_response(hub_port, session_name, full_text)
                        # Signal idle
                        if hub_port and work_dir:
                            await self._post_hook(hub_port, work_dir, "Stop", {})
                        current_run_id = ""
                        current_msg_id = ""

                    elif state == "aborted":
                        response_buffer.clear()
                        log.info("[%s] Agent run aborted", session_name)
                        if hub_port and work_dir:
                            await self._post_hook(hub_port, work_dir, "Stop", {})

                    elif state == "error":
                        response_buffer.clear()
                        error_msg = payload.get("errorMessage", str(payload))
                        log.error("[%s] Agent error: %s", session_name, error_msg)
                        if hub_port and work_dir:
                            await self._post_hook(hub_port, work_dir, "Stop", {})

                elif msg_type == "event" and event_name == "agent":
                    payload = msg.get("payload", {})
                    if payload.get("sessionKey") != our_session_key:
                        continue
                    stream = payload.get("stream", "")
                    if stream == "tool_call" and hub_port and work_dir:
                        tool_data = payload.get("data", {})
                        await self._post_hook(hub_port, work_dir, "PreToolUse", {
                            "tool_name": tool_data.get("name", "tool"),
                            "tool_input": tool_data.get("input", {}),
                        })
                    elif stream == "tool_result" and hub_port and work_dir:
                        await self._post_hook(hub_port, work_dir, "PostToolUse", {
                            "tool_name": payload.get("data", {}).get("name", "tool"),
                            "tool_input": {},
                        })

                elif msg_type == "res":
                    if not msg.get("ok"):
                        error = msg.get("error", {})
                        log.warning("[%s] Request failed: %s", session_name, error.get("message", error))

        except websockets.exceptions.ConnectionClosed:
            log.warning("[%s] Gateway WebSocket connection closed", session_name)
        except asyncio.CancelledError:
            return
        except Exception as e:
            log.error("[%s] Gateway listener error: %s", session_name, e)

    @staticmethod
    def _strip_delivery_metadata(text: str) -> str:
        """Remove Telegram/channel delivery metadata from message text.

        OpenClaw prepends delivery context like:
        - "Conversation info (untrusted metadata): {...}"
        - "Sender (untrusted metadata): {...}"
        - "Replied message (untrusted, for context): {...}"
        - "[Queued messages while agent was busy]"

        Strips these blocks, returns just the user's actual message.
        Returns empty string if nothing remains after stripping.
        """
        import re as _re
        # Strip JSON code blocks with untrusted metadata
        text = _re.sub(
            r'(?:Conversation info|Sender|Replied message)\s*\(untrusted[^)]*\):?\s*```json\s*\{[^`]*\}?\s*```',
            '', text, flags=_re.DOTALL,
        )
        # Strip queue headers
        text = _re.sub(r'\[Queued messages while agent was busy\]\s*---\s*', '', text)
        text = _re.sub(r'Queued #\d+\s*', '', text)
        # Strip System: notification lines (Telegram reactions, etc.)
        text = _re.sub(r'System: \[\d{4}-\d{2}-\d{2}[^\]]*\] Telegram [^\n]*\n?', '', text)
        # Clean up extra whitespace
        text = text.strip()
        text = _re.sub(r'\n{3,}', '\n\n', text)
        return text

    @staticmethod
    def _extract_text(message) -> str:
        """Extract plain text from a Gateway chat message.

        The message field can be:
        - A plain string
        - A dict like {"role": "assistant", "content": [{"type": "text", "text": "..."}]}
        - None
        """
        if not message:
            return ""
        if isinstance(message, str):
            return message
        if isinstance(message, dict):
            content = message.get("content", [])
            if isinstance(content, list):
                parts = []
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        parts.append(block.get("text", ""))
                    elif isinstance(block, str):
                        parts.append(block)
                return "".join(parts)
            if isinstance(content, str):
                return content
        return str(message)

    async def _send_to_hub(self, hub_port: int, data: dict) -> None:
        """Send a WS event directly to the browser via hub_state.send_to_browser."""
        try:
            send_fn = _get_send_to_browser()
            await send_fn(data)
        except Exception as e:
            log.debug("Direct browser send failed: %s", e)

    async def _forward_response(self, hub_port: int, session_name: str, text: str) -> None:
        """Forward agent response text to the hub for display."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"http://127.0.0.1:{hub_port}/api/messages/speak",
                    json={
                        "sender": session_name,
                        "message": text,
                    },
                )
        except Exception as e:
            log.error("[%s] Failed to forward response to hub: %s", session_name, e)

    async def _post_hook(self, hub_port: int, work_dir: str, event: str, extra: dict) -> None:
        """POST a hook event to the local hub."""
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"http://127.0.0.1:{hub_port}/api/hooks/tool-status",
                    json={"hook_event_name": event, "cwd": work_dir, **extra},
                )
        except Exception as e:
            log.debug("[%s] Hook POST failed: %s", work_dir, e)
