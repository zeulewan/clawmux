"""Monitor loops and hook endpoint.

Contains the unified state monitor, context poller, usage poller,
heartbeat loop, and the Claude Code / bridge hook endpoint.
"""

import asyncio
import json
import logging
import os
import re
from pathlib import Path

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

import hub_config
from state_machine import AgentState
from hub_state import (
    session_mgr, history, send_to_browser,
    _session_status_msg, _save_activity,
    _context_cache, _hist_prefix, _active_model_id,
    _load_settings, browser_clients,
)

log = logging.getLogger("hub.monitors")
router = APIRouter()


# ── Heartbeat ─────────────────────────────────────────────────────────────────

async def heartbeat_loop() -> None:
    """Ping all browser clients every 30s, remove dead connections."""
    while True:
        await asyncio.sleep(30)
        dead = []
        for ws in list(browser_clients):
            try:
                await ws.send_json({"type": "ping"})
            except Exception:
                dead.append(ws)
        for ws in dead:
            log.info("Heartbeat: removing dead client (%d remain)", len(browser_clients) - 1)
            browser_clients.discard(ws)


# ── State monitor ─────────────────────────────────────────────────────────────

async def state_monitor_loop() -> None:
    """Unified monitor loop — delegates state detection to each backend."""
    while True:
        await asyncio.sleep(3)
        for session_id in list(session_mgr.sessions):
            session = session_mgr.sessions.get(session_id)
            if not session or session.state == AgentState.DEAD or not session.work_dir:
                continue
            backend = session_mgr._get_backend(session.backend)
            usage = _context_cache.get(session_id)
            ctx_pct = usage["percent"] if usage else None
            try:
                mr = await backend.monitor_state(
                    session.tmux_session,
                    session.state,
                    context_percent=ctx_pct,
                )
            except Exception as exc:
                log.debug("[%s] monitor_state error: %s", session_id, exc)
                continue
            if mr is None:
                continue
            if mr.compaction_event is True:
                session.set_state(AgentState.COMPACTING)
                await send_to_browser({
                    "type": "compaction_status",
                    "session_id": session_id,
                    "compacting": True,
                })
                log.info("[%s] Compaction started", session_id)
            elif mr.compaction_event is False:
                session.set_state(AgentState.PROCESSING)
                await send_to_browser({
                    "type": "compaction_status",
                    "session_id": session_id,
                    "compacting": False,
                })
                log.info("[%s] Compaction finished → PROCESSING (stop hook will set IDLE)", session_id)
            if mr.stuck_fixed:
                log.info("[%s] Backend auto-fixed stuck buffer", session_id)


# ── Recovery monitor ──────────────────────────────────────────────────────────

_RECOVERY_STALE_SECONDS = 600  # 10 minutes

async def recovery_monitor_loop() -> None:
    """Periodically recover sessions stuck in broken states.

    "Broken" means PROCESSING or STARTING for longer than _RECOVERY_STALE_SECONDS
    with no hook activity.  Each backend's recover() checks runtime health and
    attempts autonomous fixes (restart serve, clear stuck buffer, etc.).
    Unrecoverable sessions are marked DEAD so the UI reflects reality.
    """
    import time as _time
    while True:
        await asyncio.sleep(30)
        now = _time.monotonic()
        for session_id in list(session_mgr.sessions):
            session = session_mgr.sessions.get(session_id)
            if not session or session.state == AgentState.DEAD:
                continue
            if session.restarting:
                continue
            if session.state not in (AgentState.PROCESSING, AgentState.STARTING):
                continue
            if session.last_state_change <= 0:
                continue
            elapsed = now - session.last_state_change
            if elapsed < _RECOVERY_STALE_SECONDS:
                continue

            backend = session_mgr._get_backend(session.backend)
            try:
                result = await backend.recover(session.tmux_session, session.work_dir)
            except Exception as exc:
                log.debug("[%s] recover() error: %s", session_id, exc)
                continue

            if result.healthy:
                continue

            log.warning("[%s] Recovery (%s): %s", session_id, session.backend, result.message)

            if result.set_dead:
                session.set_state(AgentState.DEAD)
                await send_to_browser(_session_status_msg(session))
            elif result.fixed:
                log.info("[%s] Recovery auto-fixed: %s", session_id, result.message)


# ── Context poller ────────────────────────────────────────────────────────────

async def context_poll_loop() -> None:
    """Poll context usage for all sessions every 30s, cache results."""
    while True:
        for sid in list(session_mgr.sessions):
            session = session_mgr.sessions.get(sid)
            if not session or session.state == AgentState.DEAD:
                continue
            try:
                usage = await asyncio.to_thread(session_mgr.get_context_usage, sid)
                if usage:
                    _context_cache[sid] = usage
            except Exception:
                pass
        await asyncio.sleep(30)


# ── Usage poller ──────────────────────────────────────────────────────────────

_USAGE_POLL_INTERVAL = 300  # 5 minutes — usage can change fast with many agents
_USAGE_CACHE_PATH = Path.home() / ".claude" / "usage-cache.json"
_CREDENTIALS_PATH = Path.home() / ".claude" / ".credentials.json"
_USAGE_API_URL = "https://api.anthropic.com/api/oauth/usage"

_last_good_usage: dict | None = None
_USAGE_SIDECAR = hub_config.DATA_DIR / "usage-last-good.json"


def _load_usage_sidecar() -> dict | None:
    if _USAGE_SIDECAR.exists():
        try:
            return json.loads(_USAGE_SIDECAR.read_text())
        except Exception:
            pass
    return None


def save_usage_sidecar(data: dict) -> None:
    try:
        _USAGE_SIDECAR.parent.mkdir(parents=True, exist_ok=True)
        _USAGE_SIDECAR.write_text(json.dumps(data, indent=2))
    except Exception:
        pass


def get_fallback_usage() -> dict | None:
    global _last_good_usage
    if _last_good_usage:
        return _last_good_usage
    _last_good_usage = _load_usage_sidecar()
    return _last_good_usage


def set_last_good_usage(data: dict) -> None:
    global _last_good_usage
    _last_good_usage = data


async def _fetch_usage_from_api() -> dict | None:
    if not _CREDENTIALS_PATH.exists():
        log.debug("No credentials file for usage polling")
        return None
    try:
        creds = json.loads(_CREDENTIALS_PATH.read_text())
        token = creds.get("claudeAiOauth", {}).get("accessToken")
        if not token:
            return None
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(
                _USAGE_API_URL,
                headers={
                    "Authorization": f"Bearer {token}",
                    "anthropic-beta": "oauth-2025-04-20",
                },
            )
            if resp.status_code == 429:
                log.warning("Usage API rate limited, keeping last good data")
                return None
            resp.raise_for_status()
            data = resp.json()
            if "five_hour" not in data or "error" in data:
                log.warning("Usage API returned unexpected data: %s", list(data.keys()))
                return None
            return data
    except Exception as e:
        log.warning("Usage poll failed: %s", e)
        return None


async def fetch_usage_now() -> dict | None:
    """Force-fetch fresh usage data from Anthropic API (for on-demand refresh)."""
    data = await _fetch_usage_from_api()
    if data:
        set_last_good_usage(data)
        try:
            _USAGE_CACHE_PATH.write_text(json.dumps(data, indent=2))
        except Exception:
            pass
        save_usage_sidecar(data)
    return data


async def usage_poll_loop() -> None:
    """Poll Anthropic usage API every 30 minutes."""
    await asyncio.sleep(30)
    backoff = _USAGE_POLL_INTERVAL
    while True:
        data = await _fetch_usage_from_api()
        if data:
            set_last_good_usage(data)
            try:
                _USAGE_CACHE_PATH.write_text(json.dumps(data, indent=2))
            except Exception:
                pass
            save_usage_sidecar(data)
            log.info("Usage cache refreshed (5h: %.0f%%, 7d: %.0f%%)",
                     data.get("five_hour", {}).get("utilization", 0),
                     data.get("seven_day", {}).get("utilization", 0))
            backoff = _USAGE_POLL_INTERVAL
        else:
            backoff = min(backoff * 2, _USAGE_POLL_INTERVAL * 2)
            log.warning("Usage poll failed/rate-limited, backing off to %ds", backoff)
        await asyncio.sleep(backoff)


# ── Hook endpoint ─────────────────────────────────────────────────────────────

def _session_from_cwd(cwd: str):
    for session in session_mgr.sessions.values():
        if session.work_dir and cwd.rstrip("/") == session.work_dir.rstrip("/"):
            return session
    return None


_TOOL_STATUS_MAP = {
    "Glob": "Finding files",
    "Agent": "Spawning agent",
    "WebSearch": "Searching web",
    "NotebookEdit": "Editing notebook",
}


def _tool_activity_text(tool_name: str, tool_input: dict) -> str:
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
        cmd = tool_input.get("command", "").strip()
        desc = tool_input.get("description", "")
        if desc:
            return f"Running {desc}"
        preview = cmd[:60] + ("…" if len(cmd) > 60 else "")
        return f"Running {preview}" if preview else "Running command"
    if tool_name == "Grep":
        pattern = tool_input.get("pattern", "")
        return f"Searching for {pattern}" if pattern else "Searching"
    if tool_name == "WebFetch":
        url = tool_input.get("url", "")
        try:
            from urllib.parse import urlparse
            domain = urlparse(url).netloc
            return f"Fetching {domain}" if domain else "Fetching URL"
        except Exception:
            return "Fetching URL"
    return _TOOL_STATUS_MAP.get(tool_name, tool_name)


@router.post("/api/hooks/tool-status")
async def hook_tool_status(request: Request):
    """Receive PreToolUse/PostToolUse hooks to update live session status."""
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({})

    event = data.get("hook_event_name", "")

    clawmux_sid = request.headers.get("clawmux-session", "") or request.headers.get("x-clawmux-session", "")
    session = session_mgr.sessions.get(clawmux_sid) if clawmux_sid else None
    if not session and clawmux_sid:
        session = next((s for s in session_mgr.sessions.values() if s.voice == clawmux_sid), None)
    if not session:
        cwd = data.get("cwd", "")
        session = _session_from_cwd(cwd)
    if not session:
        log.warning("[hook] %s: session not found (header=%r, known=%s)", event, clawmux_sid, list(session_mgr.sessions.keys()))
        return JSONResponse({})

    response_json = {}

    if event in ("PostToolUse", "PostToolUseFailure"):
        session.activity = ""
        session.tool_name = ""
        session.tool_input = {}
        if session.state in (AgentState.PROCESSING, AgentState.IDLE):
            session.set_state(AgentState.PROCESSING)
            await send_to_browser(_session_status_msg(session))
            await _save_activity(session, "Processing")
    elif event == "Stop":
        backend = session_mgr._get_backend(session.backend)
        if backend.handles_stop_hook_idle:
            session.set_state(AgentState.IDLE)
            session.activity = ""
            session.tool_name = ""
            session.tool_input = {}
            await _save_activity(session, "Idle")
            await send_to_browser({"session_id": session.session_id, "type": "listening", "state": "idle"})
    elif event == "PreToolUse":
        if session.state == AgentState.IDLE:
            session.set_state(AgentState.PROCESSING)
        tool_name = data.get("tool_name", "")
        tool_input = data.get("tool_input", {})
        session.tool_name = tool_name
        session.tool_input = tool_input
        session.activity = _tool_activity_text(tool_name, tool_input)
        await _save_activity(session, session.activity)
    elif event == "Notification":
        notification = data.get("notification", {})
        await send_to_browser({
            "type": "notification",
            "session_id": session.session_id,
            "notification": notification,
        })
    elif event == "SessionStart":
        session.activity = "Starting"
        await _save_activity(session, "Starting")
    elif event == "PreCompact":
        session.set_state(AgentState.COMPACTING)
        session.activity = "Compacting"
        await _save_activity(session, "Compacting")
        if session.work_dir:
            try:
                def _read_instructions() -> str:
                    parts = []
                    claude_md_path = os.path.join(session.work_dir, "CLAUDE.md")
                    if os.path.exists(claude_md_path):
                        parts.append(open(claude_md_path).read())
                    rules_dir = os.path.join(session.work_dir, ".claude", "rules")
                    if os.path.isdir(rules_dir):
                        for fname in sorted(os.listdir(rules_dir)):
                            if fname.endswith(".md"):
                                fpath = os.path.join(rules_dir, fname)
                                parts.append(f"# Rule: {fname}\n" + open(fpath).read())
                    return "\n\n".join(parts)

                instructions = await asyncio.to_thread(_read_instructions)
                if instructions:
                    response_json = {
                        "hookSpecificOutput": {
                            "hookEventName": event,
                            "additionalContext": (
                                "IMPORTANT: Your instructions and role rules are being re-injected before "
                                "compaction so they survive into the new context window. "
                                "Re-read and internalize them:\n\n" + instructions
                            ),
                        }
                    }
            except Exception:
                pass
    else:
        return JSONResponse({})

    if event not in ("PostToolUse", "PostToolUseFailure"):
        extra = {"agent_idle": True} if event == "Stop" else {}
        await send_to_browser(_session_status_msg(session, **extra))
    return JSONResponse(response_json)
