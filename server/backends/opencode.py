"""OpenCode backend — manages agents via opencode serve + HTTP message delivery."""

import asyncio
import logging
import os
import socket
from pathlib import Path
import time

import httpx

from hub_config import AGENT_COLORS
from .base import AgentBackend
from .claude_code import ClaudeCodeBackend

_PLUGIN_SRC = Path(__file__).parent.parent.parent / "opencode-plugin"

_EXTRA_PATH = "/opt/homebrew/bin:/usr/local/bin"
_SUBPROCESS_ENV = os.environ.copy()
_SUBPROCESS_ENV["PATH"] = _EXTRA_PATH + ":" + _SUBPROCESS_ENV.get("PATH", "")

log = logging.getLogger("hub.backend.opencode")

# Port range for OpenCode HTTP servers: one per session
_OPENCODE_BASE_PORT = 7700
_session_ports: dict[str, int] = {}  # session_name → port
_opencode_sessions: dict[str, str] = {}  # session_name → opencode session_id
_port_counter = 0


def _port_is_free(port: int) -> bool:
    """Check if a TCP port is available."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", port))
            return True
    except OSError:
        return False


def _alloc_port(session_name: str) -> int:
    """Allocate a free port for an OpenCode session."""
    global _port_counter
    if session_name in _session_ports:
        return _session_ports[session_name]
    # Find next free port starting from base + counter
    port = _OPENCODE_BASE_PORT + _port_counter
    while not _port_is_free(port):
        _port_counter += 1
        port = _OPENCODE_BASE_PORT + _port_counter
    _session_ports[session_name] = port
    _port_counter += 1
    return port


def _free_port(session_name: str) -> None:
    _session_ports.pop(session_name, None)


class OpenCodeBackend(AgentBackend):
    """Runs agents via opencode serve with HTTP-based message delivery.

    Spawning still uses tmux to keep sessions inspectable and to inherit
    ClawMux's colored status bar. Message delivery bypasses tmux entirely —
    it POSTs directly to the OpenCode local HTTP server.
    """

    # Reuse ClaudeCodeBackend helpers for tmux management and status bars
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
        port = _alloc_port(session_name)

        # Deploy ClawMux bridge plugin and model config into the agent workspace
        self._deploy_plugin(work_dir, model)

        # Kill any stale tmux session
        await self._cc._run(f"tmux kill-session -t {session_name} 2>/dev/null || true")

        # Create tmux session in work dir
        await self._cc._run(
            f"tmux new-session -d -s {session_name} -x 200 -y 50 -c {work_dir}"
        )

        # Apply colored status bar
        await self._cc.apply_status_bar(session_name, voice_name, voice_id)

        # Set environment variables (includes OPENCODE_PORT for bridge plugin inbox delivery)
        await self._cc._run(
            f'tmux send-keys -t {session_name} '
            f'"export CLAWMUX_SESSION_ID={session_id} '
            f'&& export CLAWMUX_WORK_DIR={work_dir} '
            f'&& export CLAWMUX_PORT={hub_port} '
            f'&& export OPENCODE_PORT={port}" Enter'
        )

        # Start opencode serve (model is configured in opencode.json, not CLI)
        opencode_cmd = f"opencode serve --port {port}"
        await self._cc._run(f'tmux send-keys -t {session_name} "{opencode_cmd}" Enter')

        # Wait for the HTTP server to become ready
        await self._wait_for_server(session_name, port)

        # Create an OpenCode session for message delivery
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                r = await client.post(f"http://localhost:{port}/session", json={})
                oc_session_id = r.json()["id"]
                _opencode_sessions[session_name] = oc_session_id
                log.info("[%s] Created OpenCode session %s", session_name, oc_session_id)
                # Write session info for bridge plugin inbox delivery
                import json as _json
                oc_info_path = Path(work_dir) / ".clawmux-opencode.json"
                oc_info_path.write_text(_json.dumps({"port": port, "session_id": oc_session_id}) + "\n")
        except Exception as e:
            log.error("[%s] Failed to create OpenCode session: %s", session_name, e)

    def restore_session(self, session_name: str, work_dir: str) -> bool:
        """Restore port/session state from .clawmux-opencode.json after hub reload.

        Returns True if state was restored successfully.
        """
        import json as _json
        info_path = Path(work_dir) / ".clawmux-opencode.json"
        if not info_path.exists():
            return False
        try:
            info = _json.loads(info_path.read_text())
            port = info["port"]
            oc_session_id = info["session_id"]
            _session_ports[session_name] = port
            _opencode_sessions[session_name] = oc_session_id
            log.info("[%s] Restored OpenCode state: port=%d, session=%s", session_name, port, oc_session_id)
            return True
        except Exception as e:
            log.error("[%s] Failed to restore OpenCode state: %s", session_name, e)
            return False

    async def terminate(self, session_name: str) -> None:
        _free_port(session_name)
        _opencode_sessions.pop(session_name, None)
        await self._cc.terminate(session_name)

    async def health_check(self, session_name: str) -> bool:
        return await self._cc.health_check(session_name)

    async def deliver_message(self, session_name: str, text: str) -> None:
        """POST the message to the OpenCode REST API (fire-and-forget)."""
        port = _session_ports.get(session_name)
        if not port:
            log.error("[%s] No port allocated — cannot deliver message", session_name)
            return
        oc_session = _opencode_sessions.get(session_name)
        if not oc_session:
            log.error("[%s] No OpenCode session — cannot deliver message", session_name)
            return
        url = f"http://localhost:{port}/session/{oc_session}/prompt_async"
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                await client.post(url, json={
                    "parts": [{"type": "text", "text": text}],
                })
        except Exception as e:
            log.error("[%s] HTTP message delivery failed: %s", session_name, e)

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

    def _deploy_plugin(self, work_dir: str, model: str = "") -> None:
        """Write opencode.json with bridge plugin and model config."""
        import json

        config_path = Path(work_dir) / "opencode.json"
        config: dict = {}
        if config_path.exists():
            try:
                config = json.loads(config_path.read_text())
            except Exception:
                pass

        # Set model if provided
        if model:
            config["model"] = model

        # Register ClawMux bridge plugin
        plugin_uri = f"file://{_PLUGIN_SRC.resolve()}"
        plugins = config.get("plugin", [])
        if plugin_uri not in plugins:
            plugins.append(plugin_uri)
        config["plugin"] = plugins

        try:
            config_path.write_text(json.dumps(config, indent=2) + "\n")
            log.info("Wrote opencode.json (model=%s) to %s", model or "default", config_path)
        except Exception as e:
            log.error("Failed to write opencode.json at %s: %s", config_path, e)

        # Ensure plugin dependencies are installed (bun may not be available)
        plugin_node_modules = _PLUGIN_SRC / "node_modules"
        if not plugin_node_modules.exists():
            import subprocess
            try:
                subprocess.run(
                    ["npm", "install", "--prefix", str(_PLUGIN_SRC.resolve())],
                    capture_output=True, timeout=30,
                    env=_SUBPROCESS_ENV,
                )
                log.info("Installed plugin dependencies via npm")
            except Exception as e:
                log.warning("Failed to install plugin dependencies: %s", e)

    async def _wait_for_server(self, session_name: str, port: int, timeout: float = 30.0) -> None:
        """Poll until the OpenCode HTTP server is accepting connections."""
        url = f"http://localhost:{port}/health"
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                async with httpx.AsyncClient(timeout=2.0) as client:
                    r = await client.get(url)
                    if r.status_code < 500:
                        log.info("[%s] OpenCode server ready on port %d", session_name, port)
                        return
            except Exception:
                pass
            await asyncio.sleep(1)
        log.warning("[%s] OpenCode server did not become ready within %.0fs", session_name, timeout)
