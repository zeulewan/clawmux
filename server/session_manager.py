"""Session lifecycle manager — delegates agent spawning to pluggable backends."""

import asyncio
import json
import logging
import re
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from hub_config import (
    DATA_DIR,
    DEFAULT_BACKEND,
    HEALTH_CHECK_INTERVAL_SECONDS,
    HUB_PORT,
    SESSIONS_DIR,
    SESSION_TIMEOUT_MINUTES,
    TMUX_SESSION_PREFIX,
    VOICE_POOL,
    VOICES,
)
from agents_store import AgentEntry, AgentsStore
from backends.codex import CodexBackend
from backends.opencode import OpenCodeBackend
from backends.openclaw import OpenClawBackend
from backends.claude_json import ClaudeJsonBackend
from project_manager import ProjectManager
from state_machine import AgentState
from template_renderer import TemplateRenderer

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
    activity: str = ""  # composed tool description (orthogonal to state)
    activity_log: list = field(default_factory=list)  # recent activity strings for UI restore on reconnect
    tool_name: str = ""  # raw tool name from last PreToolUse
    tool_input: dict = field(default_factory=dict)  # raw tool input from last PreToolUse
    project: str = ""  # current project/repo name (set by agent via set_project_status)
    project_repo: str = ""  # repository the agent is working on
    role: str = ""  # display role (e.g. "Manager", "Frontend", "Researcher")
    task: str = ""  # current task description (~5 words)
    text_mode: bool = False  # when True, skip TTS and just send text
    interjections: list[str] = field(default_factory=list)  # queued user messages sent while agent was busy
    model: str = ""  # per-session Claude model override (opus/sonnet/haiku); empty = use global default
    effort: str = ""  # per-session effort level override (low/medium/high); empty = use global default
    backend: str = DEFAULT_BACKEND  # backend type (e.g. "claude-code", "opencode", "codex")
    model_id: str = ""  # actual model string, e.g. "claude-opus-4-6", "gpt-5"
    pending_model_restart: bool = False  # True when model was changed and needs restart after current turn
    permission_mode: str = "bypassPermissions"  # permission mode for claude-json backend
    restarting: bool = False  # True while model restart is in progress (skip health checks)
    processing: bool = False  # DEPRECATED — derived from state during migration
    in_wait: bool = False  # DEPRECATED — derived from state during migration
    compacting: bool = False  # DEPRECATED — derived from state during migration
    unread_count: int = 0  # server-tracked unread message count
    # Per-session bridge state (set by hub after creation)
    playback_done: asyncio.Event | None = field(default=None, repr=False)
    conversation_id: str = ""  # conversation UUID for session resume/lookup
    project_slug: str = "default"  # which project this session belongs to
    reinject_attempts: int = 0  # number of voice-mode re-injection attempts
    max_reinject_attempts: int = 3  # max re-injection attempts before giving up
    walking_mode: bool = False  # user is walking — agent should use plain spoken text only
    last_state_change: float = 0.0  # monotonic time of last set_state() call
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False, compare=False)


    def set_state(self, new_state: AgentState) -> None:
        """Transition to a new state, syncing deprecated boolean flags."""
        import time as _time
        self.last_state_change = _time.monotonic()
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
            "activity": self.activity,
            "activity_log": self.activity_log,
            "tool_name": self.tool_name,
            "tool_input": self.tool_input,
            "project": self.project,
            "project_repo": self.project_repo,
            "role": self.role,
            "task": self.task,
            "model": self.model,
            "effort": self.effort,
            "backend": self.backend,
            "model_id": self.model_id,
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
                 agents_store: AgentsStore | None = None, backend=None,
                 on_session_death=None) -> None:
        self.sessions: dict[str, Session] = {}
        self._counter = 0
        self.history_store = history_store
        self.project_mgr = project_mgr or ProjectManager()
        self.agents_store = agents_store
        self.backend = backend  # AgentBackend instance (default backend)
        self._backends = {
            DEFAULT_BACKEND: backend,
            "opencode": OpenCodeBackend(),
            "codex": CodexBackend(),
            "openclaw": OpenClawBackend(),
            "claude-json": ClaudeJsonBackend(),
        }
        self._on_session_death = on_session_death  # async callback(session_id)
        self._template_renderer = TemplateRenderer(agents_store) if agents_store else None
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    def _get_backend(self, backend_str: str):
        """Return the backend instance for a given backend type string."""
        backend = self._backends.get(backend_str)
        if backend is None:
            log.warning("Unknown backend %r — falling back to default", backend_str)
            return self.backend
        return backend

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
            repo=session.project_repo or "",
            role=session.role or "",
            task=session.task or "",
            last_active=session.last_activity,
            model=session.model or "opus",
            effort=session.effort or "",
            backend=session.backend or DEFAULT_BACKEND,
            model_id=session.model_id or "",
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
            known_session_names.add(vid)  # voice_id: "bm_daniel" (legacy naming)
            known_session_names.add(f"{TMUX_SESSION_PREFIX}-{vname.lower()}")  # legacy: "voice-sky"
        for slug, proj in self.project_mgr.projects.items():
            if slug != "default":
                clean_slug = slug.replace("-", "")
                for vid in proj.get("voices", []):
                    vname = voice_names_map.get(vid, vid)
                    known_session_names.add(f"{clean_slug}-{vname.lower()}")  # legacy: "hnapp-bella"

        # Query ALL backends for live sessions and union the results
        live_tmux: set[str] = set()
        for b in self._backends.values():
            live_tmux |= await b.list_live_sessions(known_session_names)

        adopted = 0

        if self.agents_store:
            all_agents = await self.agents_store.all_agents()
        else:
            all_agents = {}

        for voice_id, entry in all_agents.items():
            old_session_id = entry.session_id
            if not old_session_id:
                continue

            # Compute the canonical (proper) session name from voice_id
            voice_name = voice_names_map.get(voice_id, voice_id)
            proper_id = voice_name.lower()

            # Prefer the canonical name; fall back to stored name for live lookup
            if proper_id in live_tmux:
                adopt_id = proper_id
            elif old_session_id in live_tmux:
                # Legacy voice-ID name — rename tmux session to canonical name
                if old_session_id != proper_id and proper_id not in live_tmux:
                    import subprocess as _sp
                    r = _sp.run(["tmux", "rename-session", "-t", old_session_id, proper_id],
                                capture_output=True)
                    if r.returncode == 0:
                        log.info("Renamed tmux session %s → %s", old_session_id, proper_id)
                        adopt_id = proper_id
                    else:
                        adopt_id = old_session_id
                else:
                    adopt_id = old_session_id
            else:
                log.info("No tmux for %s (%s), marking dead in agents.json", voice_id, old_session_id)
                await self._sync_agent_store(voice_id)
                continue

            # Already tracked by this hub instance
            if adopt_id in self.sessions:
                continue

            # Adopt: create a Session object with the canonical session_id
            # Derive folder assignment from projects.json voice lists (authoritative source),
            # not from entry.project which is the agent's self-reported working repo.
            adopt_project = "default"
            for slug, proj in self.project_mgr.projects.items():
                if voice_id in proj.get("voices", []):
                    adopt_project = slug
                    break
            work_dir = self.project_mgr.get_session_dir(voice_id, adopt_project)
            session = Session(
                session_id=adopt_id,
                tmux_session=adopt_id,
                work_dir=str(work_dir),
                status="ready",
                label=voice_name,
                voice=voice_id,
                project_slug=adopt_project,
            )
            session.init_bridge()
            # Restore conversation ID for context tracking
            if self.history_store:
                hist_prefix = adopt_project if adopt_project != "default" else None
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    session.conversation_id = stored_id
            # Restore project status from agents.json
            session.project = entry.project or ""
            session.project_repo = entry.repo or ""
            session.role = entry.role or ""
            session.task = entry.task or ""
            if session.project:
                log.info("Restored project status for %s: %s / %s",
                         voice_id, session.project, session.project_repo)
            # Adopted sessions are assumed idle — hub.py will flush any saved interjections
            # to inbox after cleanup_stale_sessions returns, triggering immediate injection.
            session.set_state(AgentState.IDLE)
            # Restore pending interjections from disk so hub.py can flush them
            if self.history_store:
                saved = self.history_store.load_interjections(voice_id)
                if saved:
                    session.interjections = saved
                    log.info("Loaded %d saved interjection(s) for %s — will flush to inbox", len(saved), voice_id)
            # Restore model from agents.json, fall back to hub default
            session.model = entry.model or ""
            if not session.model:
                import hub_config
                session.model = hub_config.CLAUDE_MODEL
            # Restore effort from agents.json
            session.effort = getattr(entry, 'effort', '') or ""
            # Restore backend and model_id from agents.json
            session.backend = getattr(entry, 'backend', DEFAULT_BACKEND) or DEFAULT_BACKEND
            session.model_id = getattr(entry, 'model_id', '') or ""
            # Restore backend-specific state from disk (e.g. OpenCode port/session maps)
            self._get_backend(session.backend).restore_session(adopt_id, str(work_dir))
            self.sessions[adopt_id] = session
            self._counter += 1
            adopted += 1
            log.info("Adopted orphaned session: %s (voice=%s, tmux=%s, model=%s)",
                     adopt_id, voice_id, adopt_id, session.model)
            # Apply agent-colored status bar to adopted session
            await self._get_backend(session.backend).apply_status_bar(adopt_id, voice_name, voice_id)
            # Update agents.json with restored state
            await self._sync_agent_store(voice_id, session)

        if adopted:
            log.info("Adopted %d orphaned session(s)", adopted)

        # Kill orphaned tmux sessions that are in OUR agents.json but couldn't be adopted.
        # Only kill sessions we own — never touch tmux sessions from other hub instances.
        known_tmux = {s.tmux_session for s in self.sessions.values()}
        our_session_ids = {e.session_id for e in all_agents.values() if e.session_id}
        # Also include all voice IDs so legacy voice-ID named sessions (af_bella, bm_daniel, etc.)
        # get killed if they weren't adopted as canonical names.
        our_session_ids |= {v[0] for v in VOICE_POOL}
        for name in live_tmux:
            if name not in known_tmux and name in our_session_ids and "-monitor" not in name:
                log.warning("Killing unadoptable orphaned tmux session: %s", name)
                # Determine backend from agents.json if available, else default
                orphan_backend = DEFAULT_BACKEND
                for e in all_agents.values():
                    if e.session_id == name:
                        orphan_backend = getattr(e, 'backend', DEFAULT_BACKEND) or DEFAULT_BACKEND
                        break
                await self._get_backend(orphan_backend).terminate(name)

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
        """Dispatch context usage to the session's backend."""
        session = self.sessions.get(session_id)
        if not session:
            return None
        return self._get_backend(session.backend).get_context_usage(session.tmux_session, session)

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

    async def spawn_session(self, label: str = "", voice: str = "", project: str | None = None,
                            backend: str = DEFAULT_BACKEND, model_id: str = "") -> Session:
        """Create a work dir with session config and start the agent backend."""
        # Determine which project this session belongs to.
        # If a voice is specified but no project, use the voice's existing folder
        # assignment from workspace.json — only fall back to active_project if unassigned.
        if project:
            project_slug = project
        elif voice:
            project_slug = self.project_mgr.get_voice_folder(voice) or self.project_mgr.active_project
        else:
            project_slug = self.project_mgr.active_project

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
            voice_name = pool_map.get(voice) or dict(VOICE_POOL).get(voice, voice)
        else:
            voice_id, voice_name = self._next_voice(project_slug)

        # Flat naming: just the voice name (e.g., "sky", "echo")
        session_id = voice_name.lower()
        tmux_name = session_id

        # Kill stale session with same name if it exists
        await self._get_backend(backend).terminate(tmux_name)

        session = Session(
            session_id=session_id,
            tmux_session=tmux_name,
            label=voice_name,
            voice=voice_id,
            project_slug=project_slug,
            backend=backend,
            model_id=model_id,
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
                    session.project_repo = prev.repo or ""
                if prev:
                    session.role = prev.role or ""
                    session.task = prev.task or ""

            # Write agent state to agents.json (authoritative store)
            await self._sync_agent_store(voice_id, session)

            # Check if we can resume a previous conversation for this voice
            conversation_id = None
            resuming = False
            hist_prefix = self.project_mgr.get_history_prefix(project_slug)
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    # Verify the transcript file exists on disk
                    claude_project_dir = Path.home() / ".claude" / "projects" / re.sub(r"[^a-zA-Z0-9-]", "-", str(work_dir))
                    found = (claude_project_dir / f"{stored_id}.jsonl").exists()
                    if found:
                        conversation_id = stored_id
                        resuming = True
                        log.info("[%s] Resuming conversation %s", session_id, conversation_id)
                    else:
                        log.info("[%s] Stored session %s not found, starting fresh", session_id, stored_id)

            if not conversation_id:
                conversation_id = str(uuid.uuid4())
                log.info("[%s] New conversation %s", session_id, conversation_id)
                if self.history_store:
                    self.history_store.set_claude_session_id(voice_id, conversation_id, hist_prefix)

            session.conversation_id = conversation_id

            # Write instructions for this backend only
            if self._template_renderer:
                await self._template_renderer.render_to_file(voice_id, work_dir, backend=backend)
            else:
                # Fallback: write minimal CLAUDE.md
                (work_dir / "CLAUDE.md").write_text(f"Your name is {voice_name}.\n")

            # Inject context summary from previous session history
            # Skip for claude-json — --resume already provides full conversation context
            if self.history_store and backend != "claude-json":
                hist_prefix = self.project_mgr.get_history_prefix(project_slug)
                context_summary = self.history_store.generate_context_summary(
                    voice_id, voice_name, hist_prefix
                )
                if context_summary:
                    # Append context summary to all instruction files
                    for fname in ("CLAUDE.md", "INSTRUCTIONS.md", "AGENTS.md"):
                        instructions_file = work_dir / fname
                        if instructions_file.exists():
                            existing = instructions_file.read_text()
                            instructions_file.write_text(existing + f"\n{context_summary}\n")
                    log.info("[%s] Injected context summary", session_id)

            # Backend-specific workspace preparation (e.g. trust prompts)
            backend_impl = self._get_backend(backend)
            backend_impl.prepare_workspace(str(work_dir))

            # Resolve model/effort defaults via the backend
            session_model, session_effort, spawn_model = backend_impl.resolve_spawn_params(
                session.model, session.effort, session.model_id
            )
            session.model = session_model
            session.effort = session_effort
            # Sync permission mode to backend before spawn
            if session.permission_mode != "bypassPermissions" and hasattr(backend_impl, 'set_permission_mode'):
                backend_impl.set_permission_mode(session_id, session.permission_mode)
            await backend_impl.spawn(
                session_name=tmux_name, work_dir=str(work_dir),
                session_id=session_id, hub_port=HUB_PORT,
                voice_id=voice_id, voice_name=voice_name,
                conversation_id=conversation_id,
                resuming=resuming, model=spawn_model,
                effort=session_effort,
            )

            # Deliver catch-up context if this model missed messages
            if self.history_store:
                # Normalize model key: prefer model_id, fall back to model shorthand,
                # default to "default" so the same agent always uses the same cursor key
                cursor_model = session.model_id or session.model or "default"
                hist_prefix = self.project_mgr.get_history_prefix(project_slug)
                catchup = self.history_store.generate_catchup_context(
                    voice_id, cursor_model, project=hist_prefix
                )
                if catchup:
                    await backend_impl.deliver_message(tmux_name, catchup)
                    log.info("[%s] Delivered catch-up context for model %s", session_id, cursor_model)
                # Advance cursor to head regardless (this model is now current)
                msg_count = self.history_store.message_count(voice_id, hist_prefix)
                self.history_store.set_read_cursor(voice_id, cursor_model, msg_count, hist_prefix)

            # Backends that signal readiness externally stay STARTING; others go IDLE now
            async with session._lock:
                if backend_impl.sets_idle_on_spawn:
                    session.set_state(AgentState.IDLE)
                session.status = "ready"  # legacy compat: browser checks this for mic enable
                session.touch()
            log.info("Session %s ready (backend=%s)", session_id, backend)
            return session

        except Exception as e:
            log.error("Failed to spawn session %s: %s", session_id, e)
            await self._get_backend(backend).terminate(tmux_name)
            self._cleanup_workdir(session)
            del self.sessions[session_id]
            raise

    async def spawn_openclaw_session(self, agent_name: str, agent_id: str = "main",
                                      project: str | None = None,
                                      session_key: str = "") -> Session:
        """Spawn a session for an external OpenClaw agent (no voice, no tmux).

        OpenClaw agents are always-on in the Gateway — we just connect to them.
        The session uses the agent's real name as both session_id and label.
        """
        session_id = f"oc-{agent_name.lower()}"
        project_slug = project or self.project_mgr.active_project

        # Reject duplicate
        if session_id in self.sessions:
            raise RuntimeError(f"OpenClaw agent '{agent_name}' already has an active session")

        session = Session(
            session_id=session_id,
            tmux_session=session_id,  # placeholder — no real tmux
            label=agent_name,
            voice="",  # no voice for OpenClaw agents
            project_slug=project_slug,
            backend="openclaw",
        )
        session.init_bridge()
        self.sessions[session_id] = session

        try:
            work_dir = self.project_mgr.get_session_dir(f"openclaw_{agent_id}", project_slug)
            work_dir.mkdir(parents=True, exist_ok=True)
            session.work_dir = str(work_dir)

            if self._template_renderer:
                await self._template_renderer.render_to_file(f"openclaw_{agent_id}", work_dir, backend="openclaw")

            backend_impl = self._get_backend("openclaw")
            await backend_impl.spawn(
                session_name=session_id, work_dir=str(work_dir),
                session_id=session_id, hub_port=HUB_PORT,
                voice_id="", voice_name=agent_name,
                conversation_id=str(uuid.uuid4()),
                resuming=False, model="", effort="",
                agent_id=agent_id,
                session_key=session_key,
            )

            async with session._lock:
                session.set_state(AgentState.IDLE)
                session.status = "ready"
                session.touch()
            log.info("OpenClaw session %s ready (agent=%s)", session_id, agent_id)
            return session

        except Exception as e:
            log.error("Failed to spawn OpenClaw session %s: %s", session_id, e)
            await self._get_backend("openclaw").terminate(session_id)
            del self.sessions[session_id]
            raise

    async def terminate_session(self, session_id: str) -> None:
        session = self.sessions.get(session_id)
        if not session:
            log.warning("terminate_session: unknown session %s", session_id)
            return

        log.info("Terminating session %s", session_id)
        async with session._lock:
            voice_id = session.voice
            backend_str = session.backend
            tmux = session.tmux_session
            session.set_state(AgentState.DEAD)
        await self._get_backend(backend_str).terminate(tmux)
        self._cleanup_workdir(session)
        del self.sessions[session_id]
        # Dual-write: mark agent as dead in agents.json
        await self._sync_agent_store(voice_id)

    async def restart_claude_with_model(self, session_id: str) -> None:
        """Kill and respawn the agent with a new model, resuming conversation."""
        session = self.sessions.get(session_id)
        if not session:
            return
        tmux_name = session.tmux_session
        backend_impl = self._get_backend(session.backend)
        async with session._lock:
            session_model, session_effort, _ = backend_impl.resolve_spawn_params(
                session.model, session.effort, session.model_id
            )
            session.model = session_model
            session.effort = session_effort
            conversation_id = session.conversation_id
            log.info("[%s] Restarting with model %s, effort %s", session_id, session_model, session_effort)
            session.pending_model_restart = False
            session.restarting = True
            session.set_state(AgentState.STARTING)

        # Verify the transcript file exists before resuming
        work_dir = session.work_dir
        resuming = False
        if conversation_id:
            claude_project_dir = Path.home() / ".claude" / "projects" / re.sub(r"[^a-zA-Z0-9-]", "-", work_dir)
            resuming = (claude_project_dir / f"{conversation_id}.jsonl").exists()
            if not resuming:
                log.info("[%s] Session %s not found on disk, starting fresh", session_id, conversation_id)
                conversation_id = str(uuid.uuid4())
                async with session._lock:
                    session.conversation_id = conversation_id
                if self.history_store:
                    hist_prefix = self.project_mgr.get_history_prefix(session.project_slug)
                    self.history_store.set_claude_session_id(session.voice, conversation_id, hist_prefix)

        # Delegate restart to the backend
        await backend_impl.restart(
            session_name=tmux_name, work_dir=work_dir,
            session_id=session_id, hub_port=HUB_PORT,
            voice_id=session.voice, voice_name=session.label,
            conversation_id=conversation_id, model=session_model,
            effort=session_effort,
        )

        async with session._lock:
            session.restarting = False
            # State stays STARTING — transitions to IDLE when wait WS connects
            session.status = "ready"  # legacy compat
            session.touch()
        # Persist model/effort to agents.json
        await self._sync_agent_store(session.voice, session)
        log.info("[%s] Model restart complete", session_id)

    async def check_health(self, session: Session) -> bool:
        return await self._get_backend(session.backend).health_check(session.tmux_session)

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
                    log.warning("Session %s backend died, cleaning up", session_id)
                    voice_id = session.voice
                    self._cleanup_workdir(session)
                    del self.sessions[session_id]
                    # Dual-write: mark agent as dead in agents.json
                    await self._sync_agent_store(voice_id)
                    # Notify browser of session death
                    if self._on_session_death:
                        try:
                            await self._on_session_death(session_id)
                        except Exception as e:
                            log.warning("on_session_death callback failed: %s", e)
                    continue

                if timeout > 0:
                    idle = now - session.last_activity
                    if idle > timeout:
                        log.info("Session %s timed out (%.0fs idle)", session_id, idle)
                        await self.terminate_session(session_id)

    def _cleanup_workdir(self, session: Session) -> None:
        # Don't delete voice work dirs — they persist for --resume
        # State is now managed via agents.json, so no per-agent files to clean up
        pass


