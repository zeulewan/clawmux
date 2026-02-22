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
    CLAUDE_BASE_COMMAND,
    HEALTH_CHECK_INTERVAL_SECONDS,
    HUB_PORT,
    SESSION_TIMEOUT_MINUTES,
    TMUX_SESSION_PREFIX,
    VOICES,
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
    speed: float = 1.0
    status_text: str = ""  # last status sent to browser (e.g. "Speaking...", "Transcribing...")
    project: str = ""  # current project/repo name (set by agent via set_project_status)
    project_area: str = ""  # current sub-area (e.g. "frontend", "docs")
    text_override: str = ""  # set by browser "text" message, consumed by handle_converse
    text_mode: bool = False  # when True, skip TTS and just send text
    interjections: list[str] = field(default_factory=list)  # queued user messages sent while agent was busy
    processing: bool = False  # True when agent is busy between converse calls
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
            "speed": self.speed,
            "mcp_connected": self.mcp_ws is not None,
            "status_text": self.status_text,
            "project": self.project,
            "project_area": self.project_area,
            "processing": self.processing,
        }

    def touch(self) -> None:
        self.last_activity = time.time()

    def init_bridge(self) -> None:
        self.audio_queue = asyncio.Queue()
        self.playback_done = asyncio.Event()


class SessionManager:
    def __init__(self, history_store=None) -> None:
        self.sessions: dict[str, Session] = {}
        self._counter = 0
        self.history_store = history_store
        SESSION_DIR_BASE.mkdir(parents=True, exist_ok=True)

    async def cleanup_stale_sessions(self) -> None:
        """Adopt orphaned voice-* tmux sessions from previous hub runs.

        Instead of killing orphaned sessions, re-create Session objects so the
        MCP servers inside them can reconnect to the hub.
        """
        # Build set of live tmux sessions
        live_tmux: set[str] = set()
        try:
            proc = await asyncio.create_subprocess_exec(
                "tmux", "list-sessions", "-F", "#{session_name}",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await proc.communicate()
            if proc.returncode == 0:
                for name in stdout.decode().strip().splitlines():
                    if name.startswith(TMUX_SESSION_PREFIX + "-"):
                        live_tmux.add(name)
        except Exception as e:
            log.error("Error listing tmux sessions: %s", e)

        # Scan voice work dirs for adoptable sessions
        voice_ids = {v[0] for v in VOICES}
        voice_names_map = dict(VOICES)
        adopted = 0

        for voice_id in voice_ids:
            work_dir = SESSION_DIR_BASE / voice_id
            mcp_json_path = work_dir / ".mcp.json"
            if not mcp_json_path.exists():
                continue

            try:
                mcp_config = json.loads(mcp_json_path.read_text())
                old_session_id = (
                    mcp_config.get("mcpServers", {})
                    .get("voice-hub", {})
                    .get("env", {})
                    .get("VOICE_HUB_SESSION_ID", "")
                )
            except Exception:
                continue

            if not old_session_id:
                continue

            # Check if the tmux session for this session_id still exists
            if old_session_id not in live_tmux:
                # No tmux session — clean up the stale .mcp.json
                log.info("No tmux for %s (%s), cleaning .mcp.json", voice_id, old_session_id)
                mcp_json_path.unlink(missing_ok=True)
                continue

            # Already tracked by this hub instance
            if old_session_id in self.sessions:
                continue

            # Adopt: create a Session object with the old session_id
            voice_name = voice_names_map.get(voice_id, voice_id)
            session = Session(
                session_id=old_session_id,
                tmux_session=old_session_id,
                work_dir=str(work_dir),
                status="ready",
                label=voice_name,
                voice=voice_id,
            )
            session.init_bridge()
            # Restore project status from disk
            proj_file = work_dir / ".project_status.json"
            if proj_file.exists():
                try:
                    proj_data = json.loads(proj_file.read_text())
                    session.project = proj_data.get("project", "")
                    session.project_area = proj_data.get("area", "")
                    log.info("Restored project status for %s: %s / %s",
                             voice_id, session.project, session.project_area)
                except Exception:
                    pass
            # Restore pending interjections from disk
            if self.history_store:
                saved = self.history_store.load_interjections(voice_id)
                if saved:
                    session.interjections = saved
                    session.processing = True
                    log.info("Restored %d interjection(s) for %s", len(saved), voice_id)
            self.sessions[old_session_id] = session
            self._counter += 1
            adopted += 1
            log.info("Adopted orphaned session: %s (voice=%s, tmux=%s)",
                     old_session_id, voice_id, old_session_id)

        if adopted:
            log.info("Adopted %d orphaned session(s)", adopted)

        # Kill any remaining orphaned tmux sessions that we couldn't adopt
        known_tmux = {s.tmux_session for s in self.sessions.values()}
        for name in live_tmux:
            if name not in known_tmux:
                log.warning("Killing unadoptable orphaned tmux session: %s", name)
                await self._cleanup_tmux(name)

        # Clean orphaned session work dirs (but keep voice dirs for --resume)
        try:
            for d in SESSION_DIR_BASE.iterdir():
                if d.is_dir() and d.name not in self.sessions and d.name not in voice_ids:
                    log.warning("Removing orphaned work dir: %s", d)
                    shutil.rmtree(d, ignore_errors=True)
        except Exception as e:
            log.error("Error cleaning stale work dirs: %s", e)

    def list_sessions(self) -> list[dict]:
        return [s.to_dict() for s in self.sessions.values()]

    def _next_voice(self) -> tuple[str, str]:
        """Return the next unused (voice_id, display_name) from the rotation."""
        used = {s.voice for s in self.sessions.values()}
        for voice_id, name in VOICES:
            if voice_id not in used:
                return voice_id, name
        # All used — wrap around using counter
        idx = self._counter % len(VOICES)
        return VOICES[idx]

    async def spawn_session(self, label: str = "", voice: str = "") -> Session:
        """Create a temp dir with .mcp.json, tmux session, and start Claude."""
        # Reject duplicate voice
        if voice:
            for s in self.sessions.values():
                if s.voice == voice:
                    raise RuntimeError(f"Voice {voice} already has an active session")

        self._counter += 1
        short_id = uuid.uuid4().hex[:6]

        if voice:
            # Use specified voice
            voice_id = voice
            voice_name = dict(VOICES).get(voice, voice)
        else:
            voice_id, voice_name = self._next_voice()

        # Name session after the voice (e.g. "voice-sky")
        session_id = f"{TMUX_SESSION_PREFIX}-{voice_name.lower()}"
        tmux_name = session_id

        # Kill stale tmux session with same name if it exists
        await self._run(f"tmux kill-session -t {tmux_name} 2>/dev/null || true")

        session = Session(
            session_id=session_id,
            tmux_session=tmux_name,
            label=voice_name,
            voice=voice_id,
        )
        session.init_bridge()
        self.sessions[session_id] = session

        log.info("Spawning session %s (tmux: %s)", session_id, tmux_name)

        try:
            # Use a stable work directory per voice (so --resume finds the session)
            work_dir = SESSION_DIR_BASE / voice_id
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

            # Check if we can resume a previous Claude session for this voice
            claude_session_id = None
            resuming = False
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id)
                if stored_id:
                    # Verify the session file exists somewhere in ~/.claude/projects/
                    claude_projects = Path.home() / ".claude" / "projects"
                    found = False
                    if claude_projects.exists():
                        for p in claude_projects.iterdir():
                            if (p / f"{stored_id}.jsonl").exists():
                                found = True
                                break
                    if found:
                        claude_session_id = stored_id
                        resuming = True
                        log.info("[%s] Resuming Claude session %s", session_id, claude_session_id)
                    else:
                        log.info("[%s] Stored session %s not found, starting fresh", session_id, stored_id)

            if not claude_session_id:
                # Generate a new Claude session UUID for fresh starts
                claude_session_id = str(uuid.uuid4())
                log.info("[%s] New Claude session %s", session_id, claude_session_id)
                if self.history_store:
                    self.history_store.set_claude_session_id(voice_id, claude_session_id)

            # Write CLAUDE.md with agent identity
            claude_md = work_dir / "CLAUDE.md"
            if resuming:
                identity = (
                    f"Your name is {voice_name}. "
                    f"You have an ongoing conversation with this user. "
                    f"Greet them naturally as a returning friend, "
                    f"referencing something from your recent conversation.\n"
                )
            else:
                identity = (
                    f"Your name is {voice_name}. "
                    f"When greeting the user, say: \"Hi, I'm {voice_name}! How can I help?\"\n"
                )

            # Add behavioral instructions
            identity += (
                "\n# Important Rules\n"
                "- NEVER enter plan mode. Always execute tasks directly.\n"
                "- Always operate in bypass permissions mode.\n"
                "\n# Project Status\n"
                "You MUST call `set_project_status` immediately when you start up, "
                "before doing anything else. If you know what project you're working on, "
                "set it right away. If you're just starting fresh with no context yet, "
                "set project to \"ready\". The sidebar should ALWAYS show a project status — "
                "it must never be blank.\n\n"
                "Update it whenever your context changes. Use the project/repo name as "
                "`project` (e.g. \"voice-chat\") and the sub-area as `area` "
                "(e.g. \"frontend\", \"backend\", \"docs\", \"iOS app\").\n"
                "\n# Hub Reconnection\n"
                "If a converse call returns \"(hub reconnected)\", the voice hub briefly "
                "restarted. Just continue the conversation naturally — call converse again "
                "to keep talking. Don't mention the interruption to the user.\n"
            )

            claude_md.write_text(identity)

            # Create tmux session starting in the work dir
            await self._run(
                f"tmux new-session -d -s {tmux_name} -x 200 -y 50 -c {work_dir}"
            )

            # Unset CLAUDECODE so nested Claude Code sessions don't get blocked
            await self._run(
                f'tmux send-keys -t {tmux_name} "unset CLAUDECODE" Enter'
            )

            # Send a marker so we can detect fresh output from Claude
            marker = f"__CLAUDE_INIT_{short_id}__"
            await self._run(
                f'tmux send-keys -t {tmux_name} "echo {marker}" Enter'
            )

            # Start Claude with session ID (resume or fresh)
            import hub_config
            model_flag = f" --model {hub_config.CLAUDE_MODEL}" if hub_config.CLAUDE_MODEL != "opus" else ""
            if resuming:
                claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag} --resume {claude_session_id}"
            else:
                claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag} --session-id {claude_session_id}"
            await self._run(
                f'tmux send-keys -t {tmux_name} "{claude_cmd}" Enter'
            )

            # Wait for Claude to initialize (poll for input prompt AFTER marker)
            start = time.time()
            init_deadline = start + 30
            while time.time() < init_deadline:
                try:
                    result = await self._run(
                        f"tmux capture-pane -t {tmux_name} -p"
                    )
                    if result and marker in result:
                        # Look for Claude's prompt after the marker
                        after_marker = result.split(marker, 1)[1]
                        if ">" in after_marker or "❯" in after_marker:
                            log.info("[%s] Claude ready (%.1fs)", session_id, time.time() - start)
                            break
                except Exception:
                    pass
                await asyncio.sleep(1)
            else:
                log.warning("[%s] Claude init poll timed out, sending command anyway", session_id)

            # Wait for the MCP server to connect to the hub (Claude loads it on startup)
            deadline = time.time() + 45
            while time.time() < deadline:
                if session.mcp_ws is not None:
                    break
                await asyncio.sleep(1)
            else:
                raise TimeoutError(
                    f"MCP server for session {session_id} did not connect within 45s"
                )

            # MCP connected — now send the /voice-hub skill command
            log.info("[%s] MCP connected, sending /voice-hub", session_id)
            await self._run(f'tmux send-keys -t {tmux_name} "/voice-hub" Enter')
            await asyncio.sleep(0.5)
            await self._run(f'tmux send-keys -t {tmux_name} Enter')

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
        # Don't delete voice work dirs — they persist for --resume
        # Only clean up .mcp.json so stale config doesn't interfere
        if session.work_dir:
            mcp_json = Path(session.work_dir) / ".mcp.json"
            if mcp_json.exists():
                try:
                    mcp_json.unlink()
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
