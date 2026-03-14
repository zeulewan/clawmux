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
    HEALTH_CHECK_INTERVAL_SECONDS,
    HUB_PORT,
    SESSIONS_DIR,
    SESSION_TIMEOUT_MINUTES,
    TMUX_SESSION_PREFIX,
    VOICE_POOL,
    VOICES,
)
from agents_store import AgentEntry, AgentsStore
from backends.opencode import OpenCodeBackend
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
    backend: str = "claude-code"  # backend type: "claude-code", "opencode", "gemini"
    model_id: str = ""  # actual model string, e.g. "claude-opus-4-6", "gpt-5"
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
    walking_mode: bool = False  # user is walking — agent should use plain spoken text only
    last_state_change: float = 0.0  # monotonic time of last set_state() call


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
        self.backend = backend  # AgentBackend instance (default/claude-code)
        self._backends = {
            "claude-code": backend,
            "opencode": OpenCodeBackend(),
        }
        self._on_session_death = on_session_death  # async callback(session_id)
        self._template_renderer = TemplateRenderer(agents_store) if agents_store else None
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)

    def _get_backend(self, backend_str: str):
        """Return the backend instance for a given backend type string."""
        return self._backends.get(backend_str, self.backend)

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
            backend=session.backend or "claude-code",
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
            # Restore Claude session ID for context tracking
            if self.history_store:
                hist_prefix = adopt_project if adopt_project != "default" else None
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    session.claude_session_id = stored_id
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
            session.backend = getattr(entry, 'backend', 'claude-code') or "claude-code"
            session.model_id = getattr(entry, 'model_id', '') or ""
            # Restore OpenCode port/session state from disk so HTTP delivery works after reload
            if session.backend == "opencode":
                backend_inst = self._get_backend("opencode")
                if hasattr(backend_inst, 'restore_session'):
                    backend_inst.restore_session(adopt_id, str(work_dir))
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
                await self.backend.terminate(name)

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
            last_model = None
            for line in result.stdout.strip().split("\n"):
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    usage = None
                    model = None
                    if d.get("type") == "assistant" and "message" in d:
                        msg = d["message"] if isinstance(d["message"], dict) else {}
                        usage = msg.get("usage") or d.get("usage")
                        model = msg.get("model")
                    elif d.get("type") == "assistant" and "usage" in d:
                        usage = d["usage"]
                    if usage:
                        last_usage = usage
                    if model:
                        last_model = model
                except (json.JSONDecodeError, KeyError):
                    continue
            if not last_usage:
                return None
            input_tokens = last_usage.get("input_tokens", 0)
            cache_creation = last_usage.get("cache_creation_input_tokens", 0)
            cache_read = last_usage.get("cache_read_input_tokens", 0)
            output_tokens = last_usage.get("output_tokens", 0)
            total_context = input_tokens + cache_creation + cache_read
            # Determine context limit from model — Opus 4.6 has 1M, others 200K
            context_limit = 200000
            if last_model and "opus" in last_model:
                context_limit = 1000000
            elif session.model == "opus":
                context_limit = 1000000
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

    async def spawn_session(self, label: str = "", voice: str = "", project: str | None = None,
                            backend: str = "claude-code", model_id: str = "") -> Session:
        """Create a temp dir with session config, tmux session, and start Claude."""
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

            # Check if we can resume a previous Claude session for this voice
            claude_session_id = None
            resuming = False
            hist_prefix = self.project_mgr.get_history_prefix(project_slug)
            if self.history_store:
                stored_id = self.history_store.get_claude_session_id(voice_id, hist_prefix)
                if stored_id:
                    # Verify the session file exists in the project dir matching this work_dir
                    # Claude maps /tmp/foo/bar → ~/.claude/projects/-tmp-foo-bar/
                    claude_project_dir = Path.home() / ".claude" / "projects" / re.sub(r"[^a-zA-Z0-9-]", "-", str(work_dir))
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

            # Write instructions for all backends (CLAUDE.md + INSTRUCTIONS.md + opencode.json)
            if self._template_renderer:
                await self._template_renderer.render_to_file(voice_id, work_dir)
            else:
                # Fallback: write minimal CLAUDE.md
                (work_dir / "CLAUDE.md").write_text(f"Your name is {voice_name}.\n")

            # Inject context summary from previous session history
            if self.history_store:
                hist_prefix = self.project_mgr.get_history_prefix(project_slug)
                context_summary = self.history_store.generate_context_summary(
                    voice_id, voice_name, hist_prefix
                )
                if context_summary:
                    # Append context summary to all instruction files
                    for fname in ("CLAUDE.md", "INSTRUCTIONS.md"):
                        instructions_file = work_dir / fname
                        if instructions_file.exists():
                            existing = instructions_file.read_text()
                            instructions_file.write_text(existing + f"\n{context_summary}\n")
                    log.info("[%s] Injected context summary", session_id)

            # Pre-accept workspace trust so Claude Code doesn't prompt on first launch
            self._accept_workspace_trust(str(work_dir))

            # Delegate spawning to the backend (tmux, env vars, Claude CLI, init polling)
            import hub_config
            session_model = session.model or hub_config.CLAUDE_MODEL
            session.model = session_model  # Store effective model so browser can display it
            session_effort = session.effort or hub_config.CLAUDE_EFFORT
            session.effort = session_effort
            # For non-Claude backends, pass model_id (e.g. "opencode/nemotron-3-super-free")
            # instead of the Claude model shorthand ("opus"/"sonnet")
            spawn_model = session.model_id if backend != "claude-code" and session.model_id else session_model
            await self._get_backend(backend).spawn(
                session_name=tmux_name, work_dir=str(work_dir),
                session_id=session_id, hub_port=HUB_PORT,
                voice_id=voice_id, voice_name=voice_name,
                claude_session_id=claude_session_id,
                resuming=resuming, model=spawn_model,
                effort=session_effort,
            )

            # Deliver catch-up context if this model missed messages
            if self.history_store:
                cursor_model = session.model_id or session.model
                hist_prefix = self.project_mgr.get_history_prefix(project_slug)
                catchup = self.history_store.generate_catchup_context(
                    voice_id, cursor_model, project=hist_prefix
                )
                if catchup:
                    await self._get_backend(backend).deliver_message(tmux_name, catchup)
                    log.info("[%s] Delivered catch-up context for model %s", session_id, cursor_model)
                # Advance cursor to head regardless (this model is now current)
                msg_count = self.history_store.message_count(voice_id, hist_prefix)
                self.history_store.set_read_cursor(voice_id, cursor_model, msg_count, hist_prefix)

            # State stays STARTING — transitions to IDLE when wait WS connects
            session.status = "ready"  # legacy compat: browser checks this for mic enable
            session.touch()
            log.info("Session %s ready", session_id)
            return session

        except Exception as e:
            log.error("Failed to spawn session %s: %s", session_id, e)
            await self._get_backend(backend).terminate(tmux_name)
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
        await self._get_backend(session.backend).terminate(session.tmux_session)
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
        session_effort = session.effort or hub_config.CLAUDE_EFFORT
        session.effort = session_effort
        claude_session_id = session.claude_session_id

        log.info("[%s] Restarting Claude with model %s, effort %s", session_id, session_model, session_effort)
        session.pending_model_restart = False
        session.restarting = True
        session.set_state(AgentState.STARTING)

        # Verify the session file exists before resuming
        work_dir = session.work_dir
        resuming = False
        if claude_session_id:
            claude_project_dir = Path.home() / ".claude" / "projects" / re.sub(r"[^a-zA-Z0-9-]", "-", work_dir)
            resuming = (claude_project_dir / f"{claude_session_id}.jsonl").exists()
            if not resuming:
                log.info("[%s] Session %s not found on disk, starting fresh", session_id, claude_session_id)
                claude_session_id = str(uuid.uuid4())
                session.claude_session_id = claude_session_id
                if self.history_store:
                    hist_prefix = self.project_mgr.get_history_prefix(session.project_slug)
                    self.history_store.set_claude_session_id(session.voice, claude_session_id, hist_prefix)

        # Delegate restart to the backend
        await self._get_backend(session.backend).restart(
            session_name=tmux_name, work_dir=work_dir,
            session_id=session_id, hub_port=HUB_PORT,
            voice_id=session.voice, voice_name=session.label,
            claude_session_id=claude_session_id, model=session_model,
            effort=session_effort,
        )

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
                    log.warning("Session %s tmux died, cleaning up", session_id)
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

