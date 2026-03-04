"""Inbox — per-session message file for hook-based delivery.

Each session has an inbox file at {work_dir}/.inbox.jsonl.
The hub writes messages to it (with file locking), and Claude Code's
Stop hook reads and clears it to deliver messages to the agent.

Message format (JSON Lines):
    {"id": "msg-xxx", "from": "sky", "type": "agent", "ts": 1709571234.5, "content": "..."}
"""

import fcntl
import json
import logging
import time
import uuid
from pathlib import Path

log = logging.getLogger("inbox")

INBOX_FILENAME = ".inbox.jsonl"


def _inbox_path(work_dir: str) -> Path:
    return Path(work_dir) / INBOX_FILENAME


def write(work_dir: str, msg: dict) -> dict:
    """Append a message to the inbox file. Thread/process-safe via flock.

    Args:
        work_dir: Session's working directory.
        msg: Dict with at least {from, type, content}. id and ts are added if missing.

    Returns:
        The written message dict (with id and ts filled in).
    """
    path = _inbox_path(work_dir)
    path.parent.mkdir(parents=True, exist_ok=True)

    if "id" not in msg:
        msg["id"] = f"inbox-{uuid.uuid4().hex[:8]}"
    if "ts" not in msg:
        msg["ts"] = time.time()

    line = json.dumps(msg, separators=(",", ":")) + "\n"

    with open(path, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.write(line)
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

    log.info("[inbox] Wrote to %s: %s from %s", path.name, msg["type"], msg.get("from", "?"))
    return msg


def read_and_clear(work_dir: str) -> list[dict]:
    """Atomically read all messages and clear the inbox.

    Returns:
        List of message dicts (may be empty).
    """
    path = _inbox_path(work_dir)
    if not path.exists():
        return []

    messages = []
    with open(path, "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        messages.append(json.loads(line))
                    except json.JSONDecodeError:
                        log.warning("[inbox] Skipping malformed line: %s", line[:80])
            f.seek(0)
            f.truncate()
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

    if messages:
        log.info("[inbox] Read and cleared %d messages from %s", len(messages), path)
    return messages


def peek(work_dir: str) -> int:
    """Check how many messages are pending without consuming them.

    Returns:
        Number of pending messages.
    """
    path = _inbox_path(work_dir)
    if not path.exists():
        return 0
    try:
        with open(path, "r") as f:
            return sum(1 for line in f if line.strip())
    except Exception:
        return 0


def peek_latest(work_dir: str) -> dict | None:
    """Get the latest message without consuming it.

    Returns:
        The last message dict, or None if inbox is empty.
    """
    path = _inbox_path(work_dir)
    if not path.exists():
        return None
    try:
        last = None
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        last = json.loads(line)
                    except json.JSONDecodeError:
                        pass
        return last
    except Exception:
        return None
