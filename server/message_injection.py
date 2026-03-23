"""Message delivery orchestration — inbox injection and notification.

Handles delivering queued inbox messages to agents via their backend's
deliver_message() method, with deduplication and per-session locking.
"""

import asyncio
import logging
import time

import inbox
from state_machine import AgentState
from hub_state import (
    session_mgr, send_to_browser, _session_status_msg,
    _pending_injections,
)

log = logging.getLogger("hub.injection")

# Per-session delivery locks — serializes concurrent injections
_injection_locks: dict[str, asyncio.Lock] = {}
# Recently-injected message IDs per session — prevents re-delivery within 5 min
_injected_ids: dict[str, dict[str, float]] = {}


async def inject_inbox(session, session_id: str) -> None:
    """Deliver pending inbox messages to an agent via backend injection.

    Uses a per-session lock to serialize concurrent deliveries.
    """
    lock = _injection_locks.setdefault(session_id, asyncio.Lock())
    async with lock:
        messages = await asyncio.to_thread(inbox.read_and_clear, session.work_dir)
        if not messages:
            return

        # Dedup: drop messages already injected within the last 5 minutes
        now = time.time()
        seen = _injected_ids.setdefault(session_id, {})
        expired = [k for k, ts in seen.items() if now - ts > 300]
        for k in expired:
            del seen[k]
        fresh = []
        for msg in messages:
            mid = msg.get("id", "")
            if mid and mid in seen:
                log.warning("[%s] Skipping duplicate injection of msg %s", session_id, mid)
                continue
            if mid:
                seen[mid] = now
            fresh.append(msg)
        if not fresh:
            return
        messages = fresh

        lines = []
        has_user_msg = any(m.get("type") not in ("system", "ack") for m in messages)
        if session.walking_mode and has_user_msg:
            lines.append("[SYSTEM] Walking mode active — respond in plain spoken text only. No markdown, no underscores, no special formatting.")
        for msg in messages:
            msg_type = msg.get("type", "system")
            sender = msg.get("from", "unknown")
            content = msg.get("content", "")
            msg_id = msg.get("id", "")
            if msg_type == "agent":
                lines.append(f"[MSG id:{msg_id} from:{sender}] {content}")
            elif msg_type in ("voice", "text", "file_upload"):
                lines.append(f"[VOICE id:{msg_id} from:{sender}] {content}")
            elif msg_type == "group":
                group_name = msg.get("group_name", "group")
                lines.append(f"[GROUP:{group_name} id:{msg_id} from:{sender}] {content}")
            elif msg_type == "ack":
                parent_id = msg.get("parent_id", "")
                lines.append(f"[ACK from:{sender} on:{parent_id}]")
            else:
                lines.append(f"[SYSTEM] {content}")

        text = "\n".join(lines)
        delivered = False
        try:
            await session_mgr._get_backend(session.backend).deliver_message(session.tmux_session, text)
            delivered = True
            log.info("[%s] Injected %d message(s) via %s", session_id, len(messages), session.backend or "unknown")
        except Exception as exc:
            log.error("[%s] %s injection FAILED: %s — %d message(s) returned to inbox",
                      session_id, session.backend or "unknown", exc, len(messages))
            for msg in messages:
                await asyncio.to_thread(inbox.write, session.work_dir, msg)

        if delivered:
            if session.state == AgentState.IDLE:
                session.set_state(AgentState.PROCESSING)
                await send_to_browser(_session_status_msg(session))
            await send_to_browser({
                "type": "inbox_update",
                "session_id": session_id,
                "count": 0,
            })


def _format_message(msg: dict, walking_mode: bool = False) -> str:
    """Format a single inbox message into the text line the agent receives."""
    msg_type = msg.get("type", "system")
    sender = msg.get("from", "unknown")
    content = msg.get("content", "")
    msg_id = msg.get("id", "")
    if msg_type == "agent":
        return f"[MSG id:{msg_id} from:{sender}] {content}"
    elif msg_type in ("voice", "text", "file_upload"):
        return f"[VOICE id:{msg_id} from:{sender}] {content}"
    elif msg_type == "group":
        group_name = msg.get("group_name", "group")
        return f"[GROUP:{group_name} id:{msg_id} from:{sender}] {content}"
    elif msg_type == "ack":
        parent_id = msg.get("parent_id", "")
        return f"[ACK from:{sender} on:{parent_id}]"
    else:
        return f"[SYSTEM] {content}"


async def inbox_write_and_notify(session, msg_dict: dict) -> dict:
    """Write to inbox and notify browser + wait WS.

    For claude-json: bypasses inbox file entirely — formats the message
    and delivers directly to stdin via deliver_message().
    """
    # claude-json fast path: deliver directly to stdin, skip inbox file
    if session.backend == "claude-json":
        text = _format_message(msg_dict, session.walking_mode)
        if session.walking_mode and msg_dict.get("type") not in ("system", "ack"):
            text = "[SYSTEM] Walking mode active — respond in plain spoken text only.\n" + text
        try:
            backend = session_mgr._get_backend("claude-json")
            await backend.deliver_message(session.tmux_session, text)
            if session.state == AgentState.IDLE:
                session.set_state(AgentState.PROCESSING)
                await send_to_browser(_session_status_msg(session))
            log.info("[%s] Delivered directly to stdin (%d chars)", session.session_id, len(text))
        except Exception as exc:
            log.error("[%s] Direct stdin delivery failed: %s", session.session_id, exc)
        return msg_dict

    # Standard path: write to inbox file + trigger injection
    written = await asyncio.to_thread(inbox.write, session.work_dir, msg_dict)
    count = await asyncio.to_thread(inbox.peek, session.work_dir)
    await send_to_browser({
        "type": "inbox_update",
        "session_id": session.session_id,
        "count": count,
        "latest": {
            "from": msg_dict.get("from", ""),
            "type": msg_dict.get("type", ""),
            "preview": msg_dict.get("content", "")[:100],
        },
    })
    if session.work_dir:
        task = asyncio.create_task(inject_inbox(session, session.session_id))
        _pending_injections[session.session_id] = task
    return written
