"""Session lifecycle manager — delegates agent spawning to pluggable backends."""

import asyncio
import json
import logging
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from hub_config import (
    HEALTH_CHECK_INTERVAL_SECONDS,
    HUB_PORT,
    LEGACY_SESSION_DIR,
    SESSIONS_DIR,
    SESSION_TIMEOUT_MINUTES,
    TMUX_SESSION_PREFIX,
    VOICES,
)
from agents_store import AgentEntry, AgentsStore
from project_manager import ProjectManager
from state_machine import AgentState

log = logging.getLogger("hub.sessions")


@dataclass
class Session:
    session_id: str
    tmux_session: str
    work_dir: str = ""
    state: AgentState = AgentState.STARTING  # canonical lifecycle state
    status: str = "starting"  # DEPRECATED — kept for backward compat during migration
    created_at: float = field(default_factory=time.time)
    last_activity: float = field(default_factory=time.time)
    label: str = ""
    voice: str = "af_sky"
    speed: float = 1.0
    status_text: str = ""  # last tool call description (orthogonal to state)
    project: str = ""  # current project/repo name (set by agent via set_project_status)
    project_area: str = ""  # current sub-area (e.g. "frontend", "docs")
    role: str = ""  # display role (e.g. "Manager", "Frontend", "Researcher")
    task: str = ""  # current task description (~5 words)
    text_mode: bool = False  # when True, skip TTS and just send text
    interjections: list[str] = field(default_factory=list)  # queued user messages sent while agent was busy
    model: str = ""  # per-session Claude model override (opus/sonnet/haiku); empty = use global default
    pending_model_restart: bool = False  # True when model was changed and needs restart after current turn
    restarting: bool = False  # True while model restart is in progress (skip health checks)
    processing: bool = False  # DEPRECATED — derived from state during migration
    in_wait: bool = False  # DEPRECATED — derived from state during migration
    compacting: bool = False  # DEPRECATED — derived from state during migration
    unread_count: int = 0  # server-tracked unread message count
    # Per-session bridge state (set by hub after creation)
    playback_done: asyncio.Event | None = field(default=None, repr=False)
    claude_session_id: str = ""  # Claude Code conversation UUID (for JSONL lookup)
    project_slug: str = "default"  # which project this session belongs to
    reinject_attempts: int = 0  # number of voice-mode re-injection attempts
    max_reinject_attempts: int = 3  # max re-injection attempts before giving up

    def set_state(self, new_state: AgentState) -> None:
        """Transition to a new state, syncing deprecated boolean flags."""
        self.state = new_state
        # Sync legacy booleans for backward compat
        self.processing = new_state == AgentState.PROCESSING
        self.in_wait = new_state == AgentState.IDLE
        self.compacting = new_state == AgentState.COMPACTING
        # Sync legacy status string
        if new_state == AgentState.STARTING:
            self.status = "starting"
        elif new_state == AgentState.DEAD:
            self.status = "dead"
        elif new_state == AgentState.IDLE:
            self.status = "ready"
        else:
            self.status = "active"

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "tmux_session": self.tmux_session,
            "state": self.state.value,
            # Backward compat — browser reads these until migrated (step 4)
            "status": self.status,
            "processing": self.processing,
            "in_wait": self.in_wait,
            "compacting": self.compacting,
            # Standard fields
            "created_at": self.created_at,
            "last_activity": self.last_activity,
            "label": self.label,
            "voice": self.voice,
            "speed": self.speed,
            "status_text": self.status_text,
            "project": self.project,
            "project_area": self.project_area,
            "role": self.role,
            "task": self.task,
            "model": self.model,
            "unread_count": self.unread_count,
            "work_dir": self.work_dir,
            "project_slug": self.project_slug,
        }

    def touch(self) -> None:
        self.last_activity = time.time()

    def init_bridge(self) -> None:
        self.playback_done = asyncio.Event()


class SessionManager:
    def __init__(self, history_store=None, project_mgr: ProjectManager | None = None,
                 agents_store: AgentsStore | None = None, backend=None) -> None:
        self.sessions: dict[str, Session] = {}
        self._counter = 0
        self.history_store = history_store
        self.project_mgr = project_mgr or ProjectManager()
        self.agents_store = agents_store
        self.backend = backend  # AgentBackend instance
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        if LEGACY_SESSION_DIR.exists():
            log.info("Legacy session dir found at %s — will scan for orphans", LEGACY_SESSION_DIR)

    async def _sync_agent_store(self, voice_id: str, session: Session | None = None, **overrides) -> None:
        """Dual-write: update agents.json for a voice. If session is None, marks agent as dead."""
        if not self.agents_store:
            return
        if session is None:
            await self.agents_store.update(voice_id, session_id=None, state="dead")
            return
        entry = AgentEntry(
            session_id=session.session_id,
            project=session.project or None,
            area=session.project_area or "",
            role=session.role or "worker",
            task=session.task or "",
            last_active=session.last_activity,
            model=session.model or "opus",
            state=session.state.value if hasattr(session.state, 'value') else str(session.state),
        )
        for k, v in overrides.items():
            if hasattr(entry, k):
                setattr(entry, k, v)
        await self.agents_store.set(voice_id, entry)

    async def cleanup_stale_sessions(self) -> None:
        """Adopt orphaned agent tmux sessions from previous hub runs."""
        # Build set of live tmux sessions
        from hub_config import VOICE_POOL
        voice_names_map = dict(VOICE_POOL)
        # Known session names: new flat names ("sky") + legacy prefixed ("voice-sky", "hnapp-bella")
        known_session_names: set[str] = set()
        for vid, vname in VOICE_POOL:
            known_session_names.add(vname.lower())  # flat: "sky"
            known_session_names.add(f"{TMUX_SESSION_PREFIX}-{vname.lower()}")  # legacy: "voice-sky"
        for slug, proj in self.project_mgr.projects.items():
            if slug != "default":
                clean_slug = slug.replace("-", "")
                for vid in proj.get("voices", []):
                    vname = voice_names_map.get(vid, vid)
                    known_session_names.add(f"{clean_slug}-{vname.lower()}")  # legacy: "hnapp-bella"

        live_tmux = await self.backend.list_live_sessions(known_session_names)

        adopted = 0

        if self.agents_store:
            all_agents = await self.agents_store.all_agents()
        else:
            all_agents = {}

        for voice_id, entry in all_agents.items():
            old_session_id = entry.session_id
            if not old_session_id:
                continue

            # Check if the tmux session for this session_id still exists
            if old_session_id not in live_tmux:
                log.info("No tmux for %s (%s), marking dead in agents.json", voice_id, old_session_id)
                await self._sync_agent_store(voice_id)
                continue

            # Already tracked by this hub instance
            if old_session_id in self.sessions:
                continue

            # Adopt: create a Session object with the old session_id
            voice_name = voice_names_map.get(voice_id, voice_id)
            adopt_project = entry.project or "default"
            work_dir = self.project_mgr.get_session_dir(voice_id, adopt_project)
            session = Session(
                session_id=old_session_id,
                tmux_session=old_session_id,
                work_dir=str(work_dir),
                status="ready",
                label=voice_name,
                voice=voice_id,
                project_slug=adopt_project,
            )
            session.init_bridge()
            # Restore Claude session ID for context tracking
            if self.history_store:
                hist_prefix = adopt_project if adopt_project != "default" else None
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    session.claude_session_id = stored_id
            # Restore project status from agents.json
            session.project = entry.project or ""
            session.project_area = entry.area or ""
            session.role = entry.role or ""
            session.task = entry.task or ""
            if session.project:
                log.info("Restored project status for %s: %s / %s",
                         voice_id, session.project, session.project_area)
            # Restore pending interjections from disk
            if self.history_store:
                saved = self.history_store.load_interjections(voice_id)
                if saved:
                    session.interjections = saved
                    session.set_state(AgentState.PROCESSING)
                    log.info("Restored %d interjection(s) for %s", len(saved), voice_id)
            # Restore model from agents.json, fall back to hub default
            session.model = entry.model or ""
            if not session.model:
                import hub_config
                session.model = hub_config.CLAUDE_MODEL
            self.sessions[old_session_id] = session
            self._counter += 1
            adopted += 1
            log.info("Adopted orphaned session: %s (voice=%s, tmux=%s, model=%s)",
                     old_session_id, voice_id, old_session_id, session.model)
            # Apply agent-colored status bar to adopted session
            await self.backend.apply_status_bar(old_session_id, voice_name, voice_id)
            # Update agents.json with restored state
            await self._sync_agent_store(voice_id, session)

        if adopted:
            log.info("Adopted %d orphaned session(s)", adopted)

        # Kill orphaned tmux sessions that are in OUR agents.json but couldn't be adopted.
        # Only kill sessions we own — never touch tmux sessions from other hub instances.
        known_tmux = {s.tmux_session for s in self.sessions.values()}
        our_session_ids = {e.session_id for e in all_agents.values() if e.session_id}
        for name in live_tmux:
            if name not in known_tmux and name in our_session_ids and "-monitor" not in name:
                log.warning("Killing unadoptable orphaned tmux session: %s", name)
                await self.backend.terminate(name)

        # Clean orphaned work dirs in SESSIONS_DIR only (our own directory).
        # Never touch LEGACY_SESSION_DIR — it may belong to another hub instance.
        from hub_config import VOICE_POOL
        known_voice_ids = {v[0] for v in VOICE_POOL}
        project_slugs = set(self.project_mgr.projects.keys())
        if SESSIONS_DIR.exists():
            try:
                for d in SESSIONS_DIR.iterdir():
                    if d.is_dir() and d.name not in self.sessions and d.name not in known_voice_ids and d.name not in project_slugs:
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

    async def spawn_session(self, label: str = "", voice: str = "", project: str | None = None) -> Session:
        """Create a temp dir with session config, tmux session, and start Claude."""
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

        # Flat naming: just the voice name (e.g., "sky", "echo")
        session_id = voice_name.lower()
        tmux_name = session_id

        # Kill stale session with same name if it exists
        await self.backend.terminate(tmux_name)

        session = Session(
            session_id=session_id,
            tmux_session=tmux_name,
            label=voice_name,
            voice=voice_id,
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

            # Restore project status from agents.json if available
            if self.agents_store:
                prev = await self.agents_store.get(voice_id)
                if prev and prev.project:
                    session.project = prev.project
                    session.project_area = prev.area or ""
                if prev:
                    session.role = prev.role or ""
                    session.task = prev.task or ""

            # Write agent state to agents.json (authoritative store)
            await self._sync_agent_store(voice_id, session)

            # Check if we can resume a previous Claude session for this voice
            claude_session_id = None
            resuming = False
            hist_prefix = self.project_mgr.get_history_prefix(project_slug)
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    # Verify the session file exists in the project dir matching this work_dir
                    # Claude maps /tmp/foo/bar → ~/.claude/projects/-tmp-foo-bar/
                    claude_project_dir = Path.home() / ".claude" / "projects" / str(work_dir).replace("/", "-").replace("_", "-")
                    found = (claude_project_dir / f"{stored_id}.jsonl").exists()
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

            if silent_startup:
                identity = (
                    f"Your name is {voice_name}. "
                    f"Do NOT greet the user or say anything on startup. "
                    f"Immediately run: clawmux wait\n"
                    f"This will block until a message arrives. Say nothing until you receive a message.\n"
                )
            elif resuming:
                identity = (
                    f"Your name is {voice_name}. "
                    f"You have an ongoing conversation with this user. "
                    f"Greet them with: clawmux send --to user 'Hi, I am back!'\n"
                    f"Then run: clawmux wait\n"
                )
            else:
                identity = (
                    f"Your name is {voice_name}. "
                    f"Greet the user by running: clawmux send --to user 'Hi, I am {voice_name}. How can I help?'\n"
                    f"Then run: clawmux wait\n"
                )

            # Add behavioral instructions
            identity += (
                "\n# Important Rules\n"
                "- NEVER enter plan mode. Always execute tasks directly.\n"
                "- Always operate in bypass permissions mode.\n"
                "- After being interrupted (Ctrl+C, Escape), always run `clawmux wait` to re-enter the message loop.\n"
                "- NEVER print text directly to the terminal chat. ALL communication must go through `clawmux send`. "
                "The user cannot see your terminal — they only see messages sent via ClawMux.\n"
                "- When you receive a message via hooks (while working), acknowledge it with `clawmux send` before continuing.\n"
                "\n# Formatting\n"
                "Use rich markdown formatting in your output whenever it adds clarity:\n"
                "- Use **headings** (##, ###) to organize longer responses\n"
                "- Use **code blocks** with language tags (```python, ```bash, etc.) for any code\n"
                "- Use **tables** for comparisons or structured data\n"
                "- Use **bullet lists** or **numbered lists** for steps or multiple items\n"
                "- Use **bold** for key terms, file names, and important values\n"
                "- Use *italic* for technical terms, subtle emphasis, or asides\n"
                "- Always format URLs as clickable markdown links: `[Link Text](https://url)` — never paste raw URLs\n"
                "The browser renders full markdown, so take advantage of it.\n"
            )

            identity += (
                    "\n# Communication (v0.6.0)\n"
                    "You are running in CLI mode. All communication uses the unified `clawmux send` and `clawmux wait` commands.\n\n"
                    "## Speaking to the user (TTS)\n"
                    "```bash\n"
                    "clawmux send --to user 'Your message here'\n"
                    "```\n"
                    "This triggers TTS and returns immediately. Do NOT block waiting for a response.\n\n"
                    "**IMPORTANT: Always use single quotes** for `clawmux send` messages. "
                    "Double quotes cause shell escaping issues — backslashes (in LaTeX, file paths) "
                    "and `!` get mangled by the shell before Python receives them.\n\n"
                    "## Sending a message to another agent\n"
                    "```bash\n"
                    "clawmux send --to echo 'Check the auth module'\n"
                    "```\n\n"
                    "## Replying to a specific message (threading)\n"
                    "```bash\n"
                    "clawmux send --to sky --re msg-xxx 'Here is the answer'\n"
                    "```\n\n"
                    "## Acknowledging a message (thumbs up)\n"
                    "```bash\n"
                    "clawmux send --to sky --re msg-xxx\n"
                    "```\n\n"
                    "## Waiting for messages (idle mode)\n"
                    "```bash\n"
                    "clawmux wait\n"
                    "```\n"
                    "Blocks until a message arrives (voice from user or inter-agent). The hub pushes messages in real-time. "
                    "Always call this when you have no active work.\n\n"
                    "## Setting your project status\n"
                    "```bash\n"
                    "clawmux project 'project-name' --area 'frontend'\n"
                    "```\n\n"
                    "IMPORTANT: Always use `clawmux send --to user` for ALL output to the user. "
                    "Never just print text to the terminal. Text printed directly to Claude Code "
                    "chat is NOT visible to the user in the browser.\n\n"
                    "# Message Delivery\n"
                    "Messages arrive through two mechanisms:\n"
                    "1. **Hooks** — While you're actively working (making tool calls), messages are delivered via "
                    "PostToolUse/PreToolUse hooks as additional context. You'll see them as `[MSG from:name]` or "
                    "`[VOICE from:name]` in system reminders.\n"
                    "2. **Wait** — While idle, `clawmux wait` receives pushed messages from the hub.\n\n"
                    "Process ALL messages you receive, whether from hooks or wait. For voice messages from the user, "
                    "respond with `clawmux send --to user`. For agent messages, respond with `clawmux send --to <agent>`.\n\n"
                    "# CLI Environment\n"
                    "`clawmux` is already in your PATH at `/usr/local/bin/clawmux`. "
                    "Environment variables (`CLAWMUX_SESSION_ID`, `CLAWMUX_PORT`) are automatically set. "
                    "Never `cd` into the repo directory or manually export these variables — just run `clawmux` directly.\n\n"
                    "Run `clawmux --help` to see all available commands (spawn, monitor, projects, version, update, etc.).\n\n"
                    "# Hub Management\n"
                    "NEVER use `pkill`, `kill`, or any signal-based commands to restart the hub. "
                    "Use the built-in CLI commands instead:\n"
                    "- `clawmux reload` — Gracefully restart the hub (agents auto-reconnect)\n"
                    "- `clawmux start` — Start the hub if it's not running\n"
                    "- `clawmux stop` — Stop the hub gracefully\n"
                    "- `clawmux status` — Check hub state and sessions\n"
                    "- `clawmux spawn` — Launch a new agent session\n"
                )
            # Inter-agent messaging instructions
            identity += (
                "\n# Inter-Agent Messaging\n"
                "You may receive messages from other agents. "
                "These appear as `[MSG from:agent_name]` in system reminders or via `clawmux wait`.\n\n"
                "When you receive an inter-agent message:\n"
                "1. Process the message content\n"
                "2. Do NOT speak the response out loud to the user\n"
                "3. Reply using: `clawmux send --to <sender_name> 'your reply'`\n"
                "4. Or acknowledge with: `clawmux send --to <sender_name> --re <msg_id>`\n"
            )

            # Manager role instructions
            identity += (
                "\n# Team Manager\n"
                "- **Manager 1 (Primary):** Sky — primary communication with Zeul, coordinates all agents\n"
                "- **Manager 2 (Secondary):** Sarah — can delegate tasks, spin up agents, and communicate with Zeul if Manager 1 is unavailable\n\n"
                "Do NOT use `send --to user` to speak to Zeul directly — only the manager speaks to Zeul. "
                "Route all status updates, questions, and task requests through the manager. "
                "If Zeul speaks to you directly, you may respond via `send --to user`.\n"
            )

            claude_md.write_text(identity)

            # Pre-accept workspace trust so Claude Code doesn't prompt on first launch
            self._accept_workspace_trust(str(work_dir))

            # Delegate spawning to the backend (tmux, env vars, Claude CLI, init polling)
            import hub_config
            session_model = session.model or hub_config.CLAUDE_MODEL
            session.model = session_model  # Store effective model so browser can display it
            await self.backend.spawn(
                session_name=tmux_name, work_dir=str(work_dir),
                session_id=session_id, hub_port=HUB_PORT,
                voice_id=voice_id, voice_name=voice_name,
                claude_session_id=claude_session_id,
                resuming=resuming, model=session_model,
            )

            # State stays STARTING — transitions to IDLE when wait WS connects
            session.status = "ready"  # legacy compat: browser checks this for mic enable
            session.touch()
            log.info("Session %s ready", session_id)
            return session

        except Exception as e:
            log.error("Failed to spawn session %s: %s", session_id, e)
            await self.backend.terminate(tmux_name)
            self._cleanup_workdir(session)
            del self.sessions[session_id]
            raise

    async def terminate_session(self, session_id: str) -> None:
        session = self.sessions.get(session_id)
        if not session:
            log.warning("terminate_session: unknown session %s", session_id)
            return

        log.info("Terminating session %s", session_id)
        voice_id = session.voice
        session.set_state(AgentState.DEAD)
        await self.backend.terminate(session.tmux_session)
        self._cleanup_workdir(session)
        del self.sessions[session_id]
        # Dual-write: mark agent as dead in agents.json
        await self._sync_agent_store(voice_id)

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
        session.set_state(AgentState.STARTING)

        # Verify the session file exists before resuming
        work_dir = session.work_dir
        resuming = False
        if claude_session_id:
            claude_project_dir = Path.home() / ".claude" / "projects" / work_dir.replace("/", "-").replace("_", "-")
            resuming = (claude_project_dir / f"{claude_session_id}.jsonl").exists()
            if not resuming:
                log.info("[%s] Session %s not found on disk, starting fresh", session_id, claude_session_id)
                claude_session_id = str(uuid.uuid4())
                session.claude_session_id = claude_session_id
                if self.history_store:
                    hist_prefix = self.project_mgr.get_history_prefix(session.project_slug)
                    self.history_store.set_claude_session_id(session.voice, claude_session_id, hist_prefix)

        # Delegate restart to the backend
        await self.backend.restart(
            session_name=tmux_name, work_dir=work_dir,
            session_id=session_id, hub_port=HUB_PORT,
            voice_id=session.voice, voice_name=session.label,
            claude_session_id=claude_session_id, model=session_model,
        )

        session.restarting = False
        # State stays STARTING — transitions to IDLE when wait WS connects
        session.status = "ready"  # legacy compat
        session.touch()
        log.info("[%s] Model restart complete", session_id)

    async def check_health(self, session: Session) -> bool:
        return await self.backend.health_check(session.tmux_session)

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
                    voice_id = session.voice
                    self._cleanup_workdir(session)
                    del self.sessions[session_id]
                    # Dual-write: mark agent as dead in agents.json
                    await self._sync_agent_store(voice_id)
                    continue

                # Voice mode watchdog: detect agents that dropped out of wait loop
                await self._voice_watchdog(session_id, session, now)

                if timeout > 0:
                    idle = now - session.last_activity
                    if idle > timeout:
                        log.info("Session %s timed out (%.0fs idle)", session_id, idle)
                        await self.terminate_session(session_id)

    async def _voice_watchdog(self, session_id: str, session: Session, now: float) -> None:
        """Detect agents that dropped out of voice mode and re-inject the wait command."""
        # Skip sessions that aren't in a watchdog-relevant state
        if session.state not in (AgentState.IDLE, AgentState.PROCESSING):
            return
        if session.in_wait or session.processing or session.restarting or session.compacting:
            return
        # Skip if max re-injection attempts exceeded
        if session.reinject_attempts >= session.max_reinject_attempts:
            return

        # Grace period for new sessions
        if (now - session.created_at) < 120:
            return

        # Check if clawmux is visible in the pane (actively waiting)
        try:
            result = await self.backend.capture_pane(session.tmux_session)
            if result and ("clawmux" in result.lower() or "listening" in result.lower()):
                return
        except Exception:
            pass

        # Agent appears to have dropped out of voice mode — attempt re-injection
        session.reinject_attempts += 1

        log.warning(
            "[%s] Voice watchdog: agent dropped out of voice mode, re-injecting (attempt %d/%d)",
            session_id,
            session.reinject_attempts, session.max_reinject_attempts,
        )

        try:
            # Check if Claude Code is at a prompt (has > or ❯ visible)
            result = await self.backend.capture_pane(session.tmux_session)
            if not result or (">" not in result and "❯" not in result):
                log.info("[%s] Voice watchdog: Claude not at prompt, skipping re-inject", session_id)
                return

            log.info("[%s] Voice watchdog: re-injecting clawmux wait", session_id)
            startup_msg = 'Run this exact command now: clawmux wait'
            await self.backend.deliver_message(session.tmux_session, startup_msg)
        except Exception as e:
            log.error("[%s] Voice watchdog re-inject failed: %s", session_id, e)

    def _cleanup_workdir(self, session: Session) -> None:
        # Don't delete voice work dirs — they persist for --resume
        # State is now managed via agents.json, so no per-agent files to clean up
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

