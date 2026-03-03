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
from project_manager import ProjectManager

log = logging.getLogger("hub.sessions")

# Path to the hub_mcp_server.py script
HUB_MCP_SERVER = str(Path(__file__).parent / "hub_mcp_server.py")
HUB_MCP_PYTHON = str(Path(__file__).parent.parent / ".venv" / "bin" / "python")
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
    model: str = ""  # per-session Claude model override (opus/sonnet/haiku); empty = use global default
    pending_model_restart: bool = False  # True when model was changed and needs restart after current turn
    restarting: bool = False  # True while model restart is in progress (skip health checks)
    processing: bool = False  # True when agent is busy between converse calls
    in_converse: bool = False  # True while handle_converse is running
    compacting: bool = False  # True when Claude Code is compacting context
    unread_count: int = 0  # server-tracked unread message count
    # Per-session bridge state (set by hub after creation)
    audio_queue: asyncio.Queue | None = field(default=None, repr=False)
    playback_done: asyncio.Event | None = field(default=None, repr=False)
    claude_session_id: str = ""  # Claude Code conversation UUID (for JSONL lookup)
    mode: str = "mcp"  # "mcp" or "cli"
    project_slug: str = "default"  # which project this session belongs to
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
            "model": self.model,
            "processing": self.processing,
            "in_converse": self.in_converse,
            "compacting": self.compacting,
            "unread_count": self.unread_count,
            "work_dir": self.work_dir,
            "mode": self.mode,
            "project_slug": self.project_slug,
        }

    def touch(self) -> None:
        self.last_activity = time.time()

    def init_bridge(self) -> None:
        self.audio_queue = asyncio.Queue()
        self.playback_done = asyncio.Event()


class SessionManager:
    def __init__(self, history_store=None, project_mgr: ProjectManager | None = None) -> None:
        self.sessions: dict[str, Session] = {}
        self._counter = 0
        self.history_store = history_store
        self.project_mgr = project_mgr or ProjectManager()
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
                # Collect valid tmux prefixes: "voice-" for default, "{cleanslug}-" for named projects
                valid_prefixes = [TMUX_SESSION_PREFIX + "-"]
                for slug, proj in self.project_mgr.projects.items():
                    if slug != "default" and not proj.get("flat_layout"):
                        valid_prefixes.append(slug.replace("-", "") + "-")
                for name in stdout.decode().strip().splitlines():
                    if any(name.startswith(p) for p in valid_prefixes):
                        live_tmux.add(name)
        except Exception as e:
            log.error("Error listing tmux sessions: %s", e)

        # Scan voice work dirs for adoptable sessions (all projects)
        from hub_config import VOICE_POOL
        voice_ids = {v[0] for v in VOICE_POOL}
        voice_names_map = dict(VOICE_POOL)
        adopted = 0

        # Collect all possible work dirs: flat layout + project subdirs
        work_dirs_to_scan: list[tuple[str, Path]] = []
        for voice_id in voice_ids:
            # Flat layout (default project)
            work_dirs_to_scan.append((voice_id, SESSION_DIR_BASE / voice_id))
        # Also scan project subdirectories
        for slug, proj in self.project_mgr.projects.items():
            if not proj.get("flat_layout"):
                for voice_id in proj.get("voices", []):
                    proj_dir = SESSION_DIR_BASE / slug / voice_id
                    if proj_dir.exists():
                        work_dirs_to_scan.append((voice_id, proj_dir))

        for voice_id, work_dir in work_dirs_to_scan:

            # Try .session.json first (works for both MCP and CLI modes)
            session_json_path = work_dir / ".session.json"
            mcp_json_path = work_dir / ".mcp.json"
            old_session_id = ""
            session_mode = "mcp"

            if session_json_path.exists():
                try:
                    session_data = json.loads(session_json_path.read_text())
                    old_session_id = session_data.get("session_id", "")
                    session_mode = session_data.get("mode", "mcp")
                except Exception:
                    pass
            elif mcp_json_path.exists():
                # Legacy: fall back to .mcp.json for older sessions
                try:
                    mcp_config = json.loads(mcp_json_path.read_text())
                    old_session_id = (
                        mcp_config.get("mcpServers", {})
                        .get("voice-hub", {})
                        .get("env", {})
                        .get("VOICE_HUB_SESSION_ID", "")
                    )
                except Exception:
                    pass

            if not old_session_id:
                continue

            # Check if the tmux session for this session_id still exists
            if old_session_id not in live_tmux:
                # No tmux session — clean up stale state files
                log.info("No tmux for %s (%s), cleaning state files", voice_id, old_session_id)
                session_json_path.unlink(missing_ok=True)
                mcp_json_path.unlink(missing_ok=True)
                continue

            # Already tracked by this hub instance
            if old_session_id in self.sessions:
                continue

            # Adopt: create a Session object with the old session_id
            voice_name = voice_names_map.get(voice_id, voice_id)
            # Determine project_slug from work_dir path
            adopt_project = "default"
            for slug, proj in self.project_mgr.projects.items():
                if not proj.get("flat_layout"):
                    proj_dir = SESSION_DIR_BASE / slug
                    if str(work_dir).startswith(str(proj_dir)):
                        adopt_project = slug
                        break
            session = Session(
                session_id=old_session_id,
                tmux_session=old_session_id,
                work_dir=str(work_dir),
                status="ready",
                label=voice_name,
                voice=voice_id,
                mode=session_mode,
                project_slug=adopt_project,
            )
            session.init_bridge()
            # Restore Claude session ID for context tracking
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id)
                if stored_id:
                    session.claude_session_id = stored_id
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
            # Set model to hub default if not already set
            if not session.model:
                import hub_config
                session.model = hub_config.CLAUDE_MODEL
            self.sessions[old_session_id] = session
            self._counter += 1
            adopted += 1
            log.info("Adopted orphaned session: %s (voice=%s, tmux=%s, model=%s)",
                     old_session_id, voice_id, old_session_id, session.model)

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

    def get_context_usage(self, session_id: str) -> dict | None:
        """Read the latest token usage from the session's JSONL transcript."""
        session = self.sessions.get(session_id)
        if not session or not session.claude_session_id:
            return None
        # Find the JSONL file in ~/.claude/projects/
        claude_projects = Path.home() / ".claude" / "projects"
        jsonl_path = None
        if claude_projects.exists():
            for p in claude_projects.iterdir():
                candidate = p / f"{session.claude_session_id}.jsonl"
                if candidate.exists():
                    jsonl_path = candidate
                    break
        if not jsonl_path:
            return None
        try:
            # Read last few lines to find the most recent assistant message with usage
            import subprocess
            result = subprocess.run(
                ["tail", "-50", str(jsonl_path)],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode != 0:
                return None
            last_usage = None
            for line in result.stdout.strip().split("\n"):
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    usage = None
                    if d.get("type") == "assistant" and "message" in d:
                        msg = d["message"] if isinstance(d["message"], dict) else {}
                        usage = msg.get("usage") or d.get("usage")
                    elif d.get("type") == "assistant" and "usage" in d:
                        usage = d["usage"]
                    if usage:
                        last_usage = usage
                except (json.JSONDecodeError, KeyError):
                    continue
            if not last_usage:
                return None
            input_tokens = last_usage.get("input_tokens", 0)
            cache_creation = last_usage.get("cache_creation_input_tokens", 0)
            cache_read = last_usage.get("cache_read_input_tokens", 0)
            output_tokens = last_usage.get("output_tokens", 0)
            total_context = input_tokens + cache_creation + cache_read
            # Claude context window is 200K tokens
            context_limit = 200000
            return {
                "total_context_tokens": total_context,
                "output_tokens": output_tokens,
                "context_limit": context_limit,
                "percent": round(total_context / context_limit * 100, 1),
            }
        except Exception as e:
            log.warning("Error reading context usage for %s: %s", session_id, e)
            return None

    def _next_voice(self, project_slug: str | None = None) -> tuple[str, str]:
        """Return the next unused (voice_id, display_name) from the project's voice set."""
        slug = project_slug or self.project_mgr.active_project
        project_voices = self.project_mgr.get_voices(slug)
        # Only consider voices used within THIS project, not globally
        used = {s.voice for s in self.sessions.values() if s.project_slug == slug}
        for voice_id, name in project_voices:
            if voice_id not in used:
                return voice_id, name
        # All used — wrap around using counter
        idx = self._counter % len(project_voices)
        return project_voices[idx]

    async def spawn_session(self, label: str = "", voice: str = "", mode: str = "mcp", project: str | None = None) -> Session:
        """Create a temp dir with .mcp.json, tmux session, and start Claude.

        Args:
            mode: "mcp" (default) uses the MCP server for voice. "cli" uses clawmux CLI.
        """
        # Determine which project this session belongs to
        project_slug = project or self.project_mgr.active_project

        # Reject duplicate voice within the same project
        if voice:
            for s in self.sessions.values():
                if s.voice == voice and s.project_slug == project_slug:
                    raise RuntimeError(f"Voice {voice} already has an active session in project {project_slug}")

        self._counter += 1
        short_id = uuid.uuid4().hex[:6]

        # Get voice from project-specific pool
        project_voices = self.project_mgr.get_voices(project_slug)
        pool_map = {v[0]: v[1] for v in project_voices}

        if voice:
            # Use specified voice
            voice_id = voice
            voice_name = pool_map.get(voice, dict(VOICES).get(voice, voice))
        else:
            voice_id, voice_name = self._next_voice(project_slug)

        # Name session after the voice, namespaced by project
        # Default project: "voice-sky" (backward compatible)
        # Named projects: "hnapp-bella" (project slug + short voice name)
        if project_slug == "default":
            session_id = f"{TMUX_SESSION_PREFIX}-{voice_name.lower()}"
        else:
            clean_slug = project_slug.replace("-", "")
            session_id = f"{clean_slug}-{voice_name.lower()}"
        tmux_name = session_id

        # Kill stale tmux session with same name if it exists
        await self._run(f"tmux kill-session -t {tmux_name} 2>/dev/null || true")

        session = Session(
            session_id=session_id,
            tmux_session=tmux_name,
            label=voice_name,
            voice=voice_id,
            mode=mode,
            project_slug=project_slug,
        )
        session.init_bridge()
        self.sessions[session_id] = session

        log.info("Spawning session %s (tmux: %s)", session_id, tmux_name)

        try:
            # Use a stable work directory per voice (so --resume finds the session)
            work_dir = self.project_mgr.get_session_dir(voice_id, project_slug)
            work_dir.mkdir(parents=True, exist_ok=True)
            session.work_dir = str(work_dir)

            # Write session state file (used for re-adoption after hub reload)
            (work_dir / ".session.json").write_text(json.dumps({
                "session_id": session_id,
                "mode": mode,
                "voice": voice_id,
            }))

            # Write project-level .mcp.json for MCP mode
            mcp_json_path = work_dir / ".mcp.json"
            if mode == "mcp":
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
                mcp_json_path.write_text(json.dumps(mcp_config, indent=2))
                log.info("Wrote %s", mcp_json_path)
            else:
                # CLI mode — remove stale .mcp.json if it exists
                if mcp_json_path.exists():
                    mcp_json_path.unlink()
                    log.info("Removed stale %s for CLI mode", mcp_json_path)

            # Check if we can resume a previous Claude session for this voice
            claude_session_id = None
            resuming = False
            hist_prefix = self.project_mgr.get_history_prefix(project_slug)
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
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
                    self.history_store.set_claude_session_id(voice_id, claude_session_id, hist_prefix)

            session.claude_session_id = claude_session_id

            # Write CLAUDE.md with agent identity
            claude_md = work_dir / "CLAUDE.md"

            # Check if silent startup is enabled
            silent_startup = False
            try:
                settings_path = Path("data/settings.json")
                if settings_path.exists():
                        silent_startup = json.loads(settings_path.read_text()).get("silent_startup", False)
            except Exception:
                pass

            if silent_startup and mode == "cli":
                identity = (
                    f"Your name is {voice_name}. "
                    f"Do NOT greet the user or say anything on startup. "
                    f"Immediately run: clawmux converse \"\"\n"
                    f"This will start listening silently. Say nothing until the user speaks first.\n"
                )
            elif silent_startup:
                identity = (
                    f"Your name is {voice_name}. "
                    f"Do NOT greet the user or say anything on startup. "
                    f"Immediately call converse with message=\"\" and wait_for_response=True "
                    f"to start listening silently. Say nothing until the user speaks first.\n"
                )
            elif resuming and mode == "cli":
                identity = (
                    f"Your name is {voice_name}. "
                    f"You have an ongoing conversation with this user. "
                    f"Greet them naturally as a returning friend.\n"
                )
            elif resuming:
                identity = (
                    f"Your name is {voice_name}. "
                    f"You have an ongoing conversation with this user. "
                    f"Greet them naturally as a returning friend, "
                    f"referencing something from your recent conversation.\n"
                )
            elif mode == "cli":
                identity = (
                    f"Your name is {voice_name}. "
                    f"Greet the user by running: clawmux converse \"Hi, I'm {voice_name}! How can I help?\"\n"
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
            )

            if mode == "cli":
                identity += (
                    "\n# Voice (CLI Mode)\n"
                    "You are running in CLI mode. Use the `clawmux` command for voice and messaging.\n\n"
                    "To speak to the user and listen for response:\n"
                    "```\n"
                    "clawmux converse \"Your message here\"\n"
                    "```\n\n"
                    "To speak without waiting for response:\n"
                    "```\n"
                    "clawmux converse \"Done.\" --no-listen\n"
                    "```\n\n"
                    "To end the session:\n"
                    "```\n"
                    "clawmux converse \"Goodbye!\" --goodbye\n"
                    "```\n\n"
                    "To set your project status:\n"
                    "```\n"
                    "clawmux project \"project-name\" --area \"frontend\"\n"
                    "```\n\n"
                    "To send a message to another agent:\n"
                    "```\n"
                    "clawmux send --to alloy \"Check the auth module\"\n"
                    "```\n\n"
                    "IMPORTANT: Always use clawmux converse for ALL communication with the user. "
                    "Never just print text — it won't be spoken aloud.\n"
                )
                if not silent_startup and not resuming:
                    identity += (
                        "\nStart by running: clawmux project \"ready\"\n"
                        "Then greet the user with: clawmux converse \"your greeting\"\n"
                    )
            else:
                identity += (
                    "\n# Project Status\n"
                    "You MUST call `set_project_status` immediately when you start up, "
                    "before doing anything else. If you know what project you're working on, "
                    "set it right away. If you're just starting fresh with no context yet, "
                    "set project to \"ready\". The sidebar should ALWAYS show a project status — "
                    "it must never be blank.\n\n"
                    "Update it whenever your context changes. Use the project/repo name as "
                    "`project` (e.g. \"voice-hub\") and the sub-area as `area` "
                    "(e.g. \"frontend\", \"backend\", \"docs\", \"iOS app\").\n"
                    "\n# Hub Reconnection\n"
                    "If a converse call returns \"(hub reconnected)\", the hub briefly restarted. "
                    "Immediately call converse with message=\"\" and wait_for_response=True to resume "
                    "listening silently. Do NOT say anything — no greeting, no acknowledgment, no mention "
                    "of the restart. The conversation is intact. Just listen.\n"
                )

            # Inter-agent messaging instructions (both modes)
            identity += (
                "\n# Inter-Agent Messaging\n"
                "You may receive messages from other agents during conversation. "
                "These appear as text starting with `[MSG id:xxx from:agent_name]`.\n\n"
                "When you receive an inter-agent message:\n"
                "1. Process the message content\n"
                "2. Do NOT speak the response out loud to the user\n"
                "3. Reply using the messaging system, not voice\n"
            )
            if mode == "cli":
                identity += (
                    "4. Reply with: `clawmux send --to <sender_name> \"your reply\"`\n"
                    "5. Acknowledge with: `clawmux ack <msg_id>`\n"
                )
            else:
                identity += (
                    "4. Reply by calling the `send_message` MCP tool or via the hub API\n"
                )
            identity += (
                "\nKeep the user informed about inter-agent messages by briefly mentioning "
                "\"I got a message from X about Y\" in your next converse call, but don't "
                "read the full message aloud.\n"
            )

            # Manager role instructions
            identity += (
                "\n# Team Manager\n"
                "Zeul may assign one agent as the team manager. The manager coordinates all agents and "
                "is the sole communication channel between agents and Zeul. When a manager is assigned:\n"
                "- The manager will broadcast to all agents that they are the manager\n"
                "- Do NOT use converse to speak to Zeul directly — only the manager speaks to Zeul\n"
                "- Route all status updates, questions, and task requests through the manager via the messaging API\n"
                "- You may still communicate directly with other agents for coordination\n"
                "- If Zeul speaks to you directly (you hear a message clearly addressed to you), you may respond via converse\n"
                "- If no manager is assigned, you may speak to Zeul directly via converse as normal\n"
            )

            claude_md.write_text(identity)

            # Pre-accept workspace trust so Claude Code doesn't prompt on first launch
            self._accept_workspace_trust(str(work_dir))

            # Create tmux session starting in the work dir
            await self._run(
                f"tmux new-session -d -s {tmux_name} -x 200 -y 50 -c {work_dir}"
            )

            # Unset CLAUDECODE so nested Claude Code sessions don't get blocked
            # Export session ID so clawmux CLI can identify this session
            await self._run(
                f'tmux send-keys -t {tmux_name} "unset CLAUDECODE && export VOICE_HUB_SESSION_ID={session_id} && export VOICE_CHAT_HUB_PORT={HUB_PORT}" Enter'
            )

            # Send a marker so we can detect fresh output from Claude
            marker = f"__CLAUDE_INIT_{short_id}__"
            await self._run(
                f'tmux send-keys -t {tmux_name} "echo {marker}" Enter'
            )

            # Start Claude with session ID (resume or fresh)
            import hub_config
            session_model = session.model or hub_config.CLAUDE_MODEL
            session.model = session_model  # Store effective model so browser can display it
            model_flag = f" --model {session_model}" if session_model != "opus" else ""
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

            if mode == "mcp":
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
            else:
                # CLI mode — wait for Claude Code to fully initialize before injecting
                # The > prompt appears early but Claude isn't ready for input yet,
                # especially on --resume where context loads after the prompt shows.
                # Poll for the status bar (contains model name) as a reliable readiness signal.
                log.info("[%s] CLI mode — waiting for full initialization", session_id)
                ready_deadline = time.time() + 30
                while time.time() < ready_deadline:
                    try:
                        # Capture the entire pane including status bar
                        result = await self._run(
                            f"tmux capture-pane -t {tmux_name} -p -e"
                        )
                        # Claude Code shows model info in status bar when ready
                        if result and ("Opus" in result or "Sonnet" in result or "Haiku" in result
                                       or "opus" in result or "sonnet" in result or "haiku" in result
                                       or "bypass" in result or "plan" in result):
                            log.info("[%s] Claude Code fully initialized", session_id)
                            break
                    except Exception:
                        pass
                    await asyncio.sleep(1)
                else:
                    log.warning("[%s] Claude Code init poll timed out, injecting anyway", session_id)

                # Small extra delay for input buffer to be ready
                await asyncio.sleep(1)

                # Send startup command
                log.info("[%s] CLI mode — sending startup prompt", session_id)
                if silent_startup:
                    startup_msg = 'Run this exact command now: clawmux converse ""'
                elif resuming:
                    startup_msg = "Run this exact command now: clawmux converse \"Hey there!\""
                else:
                    startup_msg = f"Run this exact command now: clawmux converse \"Hi, this is {voice_name}! How can I help?\""
                await self._tmux_type(tmux_name, startup_msg)
                await asyncio.sleep(1)
                # Send Enter to confirm (Claude Code may prompt for confirmation)
                await self._run(f'tmux send-keys -t {tmux_name} Enter')

            session.status = "ready"
            session.touch()
            log.info("Session %s ready (%s mode)", session_id, mode)
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

    async def restart_claude_with_model(self, session_id: str) -> None:
        """Kill and respawn Claude in existing tmux with new model, resuming conversation."""
        session = self.sessions.get(session_id)
        if not session:
            return
        tmux_name = session.tmux_session
        import hub_config
        session_model = session.model or hub_config.CLAUDE_MODEL
        session.model = session_model  # Store effective model
        model_flag = f" --model {session_model}" if session_model != "opus" else ""
        claude_session_id = session.claude_session_id

        log.info("[%s] Restarting Claude with model %s", session_id, session_model)
        session.pending_model_restart = False
        session.restarting = True
        session.status = "starting"

        # Close existing MCP connection
        if session.mcp_ws:
            try:
                await session.mcp_ws.close(code=1001, reason="Model restart")
            except Exception:
                pass
            session.mcp_ws = None

        # Kill the entire tmux session (cleanly kills all processes inside)
        await self._cleanup_tmux(tmux_name)
        await asyncio.sleep(1)

        # Recreate the tmux session in the same work dir
        work_dir = session.work_dir
        await self._run(
            f"tmux new-session -d -s {tmux_name} -x 200 -y 50 -c {work_dir}"
        )
        await self._run(
            f'tmux send-keys -t {tmux_name} "unset CLAUDECODE && export VOICE_HUB_SESSION_ID={session_id} && export VOICE_CHAT_HUB_PORT={HUB_PORT}" Enter'
        )

        # Send marker for detecting Claude readiness
        marker = f"__CLAUDE_RESTART_{session_id[-8:]}__"
        await self._run(f'tmux send-keys -t {tmux_name} "echo {marker}" Enter')
        await asyncio.sleep(0.5)

        # Start Claude with --resume and new model
        claude_cmd = f"{CLAUDE_BASE_COMMAND}{model_flag} --resume {claude_session_id}"
        await self._run(f'tmux send-keys -t {tmux_name} "{claude_cmd}" Enter')

        # Wait for Claude to initialize
        start = time.time()
        init_deadline = start + 30
        while time.time() < init_deadline:
            try:
                result = await self._run(f"tmux capture-pane -t {tmux_name} -p")
                if result and marker in result:
                    after_marker = result.split(marker, 1)[1]
                    if ">" in after_marker or "❯" in after_marker:
                        log.info("[%s] Claude restarted (%.1fs)", session_id, time.time() - start)
                        break
            except Exception:
                pass
            await asyncio.sleep(1)
        else:
            log.warning("[%s] Claude restart poll timed out", session_id)

        if session.mode == "cli":
            # CLI mode — send startup command
            log.info("[%s] CLI mode restart — sending startup prompt", session_id)
            startup_msg = 'Run this exact command now: clawmux converse ""'
            await self._tmux_type(tmux_name, startup_msg)
            await asyncio.sleep(0.5)
            await self._run(f'tmux send-keys -t {tmux_name} Enter')
        else:
            # Wait for MCP server to reconnect
            deadline = time.time() + 45
            while time.time() < deadline:
                if session.mcp_ws is not None:
                    break
                await asyncio.sleep(1)
            else:
                log.error("[%s] MCP server did not reconnect after model restart", session_id)
                session.restarting = False
                return

            # Send /voice-hub skill command
            log.info("[%s] MCP reconnected after restart, sending /voice-hub", session_id)
            await self._run(f'tmux send-keys -t {tmux_name} "/voice-hub" Enter')
            await asyncio.sleep(0.5)
            await self._run(f'tmux send-keys -t {tmux_name} Enter')

        session.restarting = False
        session.status = "ready"
        session.touch()
        log.info("[%s] Model restart complete", session_id)

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

                if session.restarting:
                    continue  # Skip health check during model restart
                alive = await self.check_health(session)
                if not alive:
                    log.warning("Session %s tmux died, cleaning up", session_id)
                    self._cleanup_workdir(session)
                    del self.sessions[session_id]
                    continue

                if timeout > 0:
                    idle = now - session.last_activity
                    if idle > timeout:
                        log.info("Session %s timed out (%.0fs idle)", session_id, idle)
                        await self.terminate_session(session_id)

    def _cleanup_workdir(self, session: Session) -> None:
        # Don't delete voice work dirs — they persist for --resume
        # Only clean up state files so stale config doesn't interfere
        if session.work_dir:
            for name in (".mcp.json", ".session.json"):
                p = Path(session.work_dir) / name
                if p.exists():
                    try:
                        p.unlink()
                    except Exception:
                        pass

    def _accept_workspace_trust(self, work_dir: str) -> None:
        """Pre-accept Claude Code workspace trust for the session work dir.

        Claude Code stores trust state in ~/.claude.json (not ~/.claude/settings.json).
        """
        claude_json_path = Path.home() / ".claude.json"
        try:
            settings = json.loads(claude_json_path.read_text()) if claude_json_path.exists() else {}
            projects = settings.setdefault("projects", {})
            proj = projects.setdefault(work_dir, {})
            proj["hasTrustDialogAccepted"] = True
            claude_json_path.write_text(json.dumps(settings, indent=2))
            log.info("Workspace trust pre-accepted for %s", work_dir)
        except Exception as e:
            log.warning("Could not pre-accept workspace trust: %s", e)

    async def _cleanup_tmux(self, tmux_name: str) -> None:
        try:
            await self._run(f"tmux kill-session -t {tmux_name}")
        except Exception:
            pass

    async def _tmux_type(self, tmux_name: str, text: str) -> None:
        """Type text literally into a tmux pane and press Enter.

        Uses subprocess_exec with -l flag to avoid shell quoting issues
        with special characters (quotes, apostrophes, exclamation marks).
        """
        # send-keys -l sends literal text (no key name interpretation)
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", tmux_name, "-l", text,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await proc.communicate()
        # Send Enter as a separate key
        proc = await asyncio.create_subprocess_exec(
            "tmux", "send-keys", "-t", tmux_name, "Enter",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await proc.communicate()

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
