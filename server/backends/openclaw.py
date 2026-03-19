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


# Per-session state
_connections: dict[str, object] = {}     # session_name → websocket connection
_listeners: dict[str, asyncio.Task] = {} # session_name → listener task
_hub_ports: dict[str, int] = {}          # session_name → hub port (for hook POSTs)
_work_dirs: dict[str, str] = {}          # session_name → work_dir (for session lookup)


class OpenClawBackend(AgentBackend):
    """Connects to OpenClaw Gateway via WebSocket for message delivery.

    Phase 1: basic connection, handshake, deliver_message, response forwarding.
    No tmux, no pane capture, no stuck buffer detection.
    """

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
    ) -> None:
        """Connect to Gateway WS and start listening for agent events."""
        gateway_url = hub_config.OPENCLAW_GATEWAY_URL
        token = hub_config.OPENCLAW_GATEWAY_TOKEN

        _hub_ports[session_name] = hub_port
        _work_dirs[session_name] = work_dir

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
        log.info("[%s] Disconnected from OpenClaw Gateway", session_name)

    async def health_check(self, session_name: str) -> bool:
        ws = _connections.get(session_name)
        if not ws:
            return False
        try:
            return ws.open
        except Exception:
            return False

    async def deliver_message(self, session_name: str, text: str) -> None:
        """Send a message to the OpenClaw agent via Gateway chat.send."""
        ws = _connections.get(session_name)
        if not ws:
            log.error("[%s] No Gateway connection — cannot deliver message", session_name)
            return

        req_id = f"clawmux-{uuid.uuid4().hex[:8]}"
        request = {
            "type": "req",
            "id": req_id,
            "method": "chat.send",
            "params": {
                "message": text,
                "agentId": "main",
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
        req_id = f"clawmux-abort-{uuid.uuid4().hex[:8]}"
        try:
            await ws.send(json.dumps({
                "type": "req",
                "id": req_id,
                "method": "chat.abort",
                "params": {},
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
        client_id = f"clawmux-{session_name}"
        client_mode = "operator"
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
        response_buffer: list[str] = []

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
                    state = payload.get("state", "")

                    if state == "delta":
                        # Streaming text chunk — accumulate
                        text = payload.get("message")
                        if text:
                            response_buffer.append(str(text))

                    elif state == "final":
                        # Agent finished — flush accumulated text
                        # Final may also contain the complete message
                        final_text = payload.get("message")
                        if final_text and not response_buffer:
                            response_buffer.append(str(final_text))
                        if response_buffer and hub_port:
                            full_text = "".join(response_buffer)
                            response_buffer.clear()
                            await self._forward_response(hub_port, session_name, full_text)
                        elif response_buffer:
                            response_buffer.clear()
                        # Signal idle
                        if hub_port and work_dir:
                            await self._post_hook(hub_port, work_dir, "Stop", {})

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
                    # Agent tool calls / results — log for debugging
                    payload = msg.get("payload", {})
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
