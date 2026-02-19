"""Session lifecycle manager — tmux + Claude Code spawning, health checks, timeout."""

import asyncio
import json
import logging
import os
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from hub_config import (
    CLAUDE_COMMAND,
    HEALTH_CHECK_INTERVAL_SECONDS,
    HUB_PORT,
    SESSION_TIMEOUT_MINUTES,
    TMUX_SESSION_PREFIX,
)

log = logging.getLogger("hub.sessions")

# Path to the hub_mcp_server.py script
HUB_MCP_SERVER = str(Path(__file__).parent / "hub_mcp_server.py")
HUB_MCP_PYTHON = str(Path(__file__).parent / ".venv" / "bin" / "python")
SESSION_DIR_BASE = Path("/tmp/voice-hub-sessions")


@dataclass
class Session:
    session_id: str
    tmux_session: str
    work_dir: str = ""
    status: str = "starting"  # starting | ready | active | dead
    created_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)
    label: str = ""
    voice: str = "af_sky"

    # Per-session bridge state (set by hub after creation)
    audio_queue: asyncio.Queue | None = field(default=None, repr=False)
    playback_done: asyncio.Event | None = field(default=None, repr=False)
    mcp_ws: object | None = field(default=None, repr=False)

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "tmux_session": self.tmux_session,
            "status": self.status,
            "created_at": self.created_at,
            "last_activity": self.last_activity,
            "label": self.label,
            "voice": self.voice,
            "mcp_connected": self.mcp_ws is not None,
        }

    def touch(self) -> None:
        self.last_activity = time.time()

    def init_bridge(self) -> None:
        self.audio_queue = asyncio.Queue()
        self.playback_done = asyncio.Event()


class SessionManager:
    def __init__(self) -> None:
        self.sessions: dict[str, Session] = {}
        self._counter = 0
        SESSION_DIR_BASE.mkdir(parents=True, exist_ok=True)

    def list_sessions(self) -> list[dict]:
        return [s.to_dict() for s in self.sessions.values()]

    async def spawn_session(self, label: str = "") -> Session:
        """Create a temp dir with .mcp.json, tmux session, and start Claude."""
        self._counter += 1
        short_id = uuid.uuid4().hex[:6]
        session_id = f"{TMUX_SESSION_PREFIX}-{self._counter}-{short_id}"
        tmux_name = session_id  # unique tmux name avoids collisions on restart

        # Kill stale tmux session with same name if it exists
        await self._run(f"tmux kill-session -t {tmux_name} 2>/dev/null || true")

        session = Session(
            session_id=session_id,
            tmux_session=tmux_name,
            label=label or f"Session {self._counter}",
        )
        session.init_bridge()
        self.sessions[session_id] = session

        log.info("Spawning session %s (tmux: %s)", session_id, tmux_name)

        try:
            # Create session work directory with .mcp.json
            work_dir = SESSION_DIR_BASE / session_id
            work_dir.mkdir(parents=True, exist_ok=True)
            session.work_dir = str(work_dir)

            # Write project-level .mcp.json with session_id baked in
            mcp_config = {
                "mcpServers": {
                    "voice-hub": {
                        "command": HUB_MCP_PYTHON,
                        "args": [HUB_MCP_SERVER],
                        "env": {
                            "VOICE_HUB_SESSION_ID": session_id,
                            "VOICE_CHAT_HUB_PORT": str(HUB_PORT),
                        },
                    }
                }
            }
            mcp_json_path = work_dir / ".mcp.json"
            mcp_json_path.write_text(json.dumps(mcp_config, indent=2))
            log.info("Wrote %s", mcp_json_path)

            # Create tmux session starting in the work dir
            await self._run(
                f"tmux new-session -d -s {tmux_name} -x 200 -y 50 -c {work_dir}"
            )

            # Start Claude (it picks up .mcp.json from the work dir)
            await self._run(
                f'tmux send-keys -t {tmux_name} "{CLAUDE_COMMAND}" Enter'
            )

            # Wait for Claude to initialize and MCP servers to start
            await asyncio.sleep(10)

            # Send /voice-hub slash command
            await self._run(f'tmux send-keys -t {tmux_name} "/voice-hub" Enter')
            await asyncio.sleep(1)
            await self._run(f'tmux send-keys -t {tmux_name} Enter')

            # Wait for the MCP server to connect to the hub
            deadline = time.time() + 45
            while time.time() < deadline:
                if session.mcp_ws is not None:
                    break
                await asyncio.sleep(1)
            else:
                raise TimeoutError(
                    f"MCP server for session {session_id} did not connect within 45s"
                )

            session.status = "ready"
            session.touch()
            log.info("Session %s ready", session_id)
            return session

        except Exception as e:
            log.error("Failed to spawn session %s: %s", session_id, e)
            await self._cleanup_tmux(tmux_name)
            self._cleanup_workdir(session)
            del self.sessions[session_id]
            raise

    async def terminate_session(self, session_id: str) -> None:
        session = self.sessions.get(session_id)
        if not session:
            log.warning("terminate_session: unknown session %s", session_id)
            return

        log.info("Terminating session %s", session_id)
        session.status = "dead"
        if session.mcp_ws:
            try:
                await session.mcp_ws.close(code=1001, reason="Session terminated")
            except Exception:
                pass
            session.mcp_ws = None
        await self._cleanup_tmux(session.tmux_session)
        self._cleanup_workdir(session)
        del self.sessions[session_id]

    async def check_health(self, session: Session) -> bool:
        proc = await asyncio.create_subprocess_exec(
            "tmux", "has-session", "-t", session.tmux_session,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        await proc.wait()
        return proc.returncode == 0

    async def run_timeout_loop(self) -> None:
        while True:
            await asyncio.sleep(HEALTH_CHECK_INTERVAL_SECONDS)
            now = time.time()
            timeout = SESSION_TIMEOUT_MINUTES * 60

            for session_id in list(self.sessions):
                session = self.sessions.get(session_id)
                if not session:
                    continue

                alive = await self.check_health(session)
                if not alive:
                    log.warning("Session %s tmux died, cleaning up", session_id)
                    self._cleanup_workdir(session)
                    del self.sessions[session_id]
                    continue

                idle = now - session.last_activity
                if idle > timeout:
                    log.info("Session %s timed out (%.0fs idle)", session_id, idle)
                    await self.terminate_session(session_id)

    def _cleanup_workdir(self, session: Session) -> None:
        if session.work_dir and os.path.exists(session.work_dir):
            try:
                shutil.rmtree(session.work_dir)
            except Exception:
                pass

    async def _cleanup_tmux(self, tmux_name: str) -> None:
        try:
            await self._run(f"tmux kill-session -t {tmux_name}")
        except Exception:
            pass

    async def _run(self, cmd: str) -> str:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(f"Command failed ({proc.returncode}): {cmd}\n{stderr.decode()}")
        return stdout.decode()
