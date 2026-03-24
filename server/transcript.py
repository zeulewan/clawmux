"""Backend-agnostic JSONL transcript parser.

Reads Claude Code transcript files (~/.claude/projects/<hash>/<session-id>.jsonl)
and returns structured messages suitable for chat display.

Handles:
- compact_boundary: only returns messages AFTER the last boundary
- Filters to user/assistant (skips system, progress, metadata)
- Extracts text + tool calls from content blocks
- Works for both claude-code (tmux) and claude-json backends
"""

import json
import logging
import re
from datetime import datetime
from pathlib import Path

log = logging.getLogger("hub.transcript")

_CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "projects"


def _extract_clawmux_send_text(cmd: str) -> str:
    """Extract the message text from a 'clawmux send --to user' command.

    Handles both single-quoted and double-quoted messages:
    - clawmux send --to user 'Hello world'
    - clawmux send --to user "Hello world"
    - clawmux send --to user --re msg-xxx 'Hello'

    Returns empty string if not a user-facing send command.
    """
    if not cmd or "clawmux send" not in cmd:
        return ""
    # Must be sending to user (not to another agent)
    if "--to user" not in cmd:
        return ""
    # Skip bare acks (--re with no message body)
    parts = cmd.split("--to user", 1)
    if len(parts) < 2:
        return ""
    after_to = parts[1].strip()
    # Skip --re only (bare ack)
    if after_to.startswith("--re ") and "'" not in after_to and '"' not in after_to:
        return ""
    # Extract quoted message — find first quote after flags
    # Remove --re msg-xxx if present
    import re as _re
    after_to = _re.sub(r'--re\s+\S+\s*', '', after_to).strip()
    if not after_to:
        return ""
    # Single-quoted
    if after_to.startswith("'"):
        # Find matching end quote (handle escaped quotes)
        text = after_to[1:]
        # Shell single quotes: no escaping inside, but '\'' is shell idiom
        text = text.replace("'\\''", "'")
        if text.endswith("'"):
            text = text[:-1]
        return text.strip()
    # Double-quoted
    if after_to.startswith('"'):
        text = after_to[1:]
        if text.endswith('"'):
            text = text[:-1]
        return text.strip()
    # Unquoted (less common)
    return after_to.strip()

# Entry types to display
_DISPLAY_TYPES = {"user", "assistant"}

# Entry types / subtypes to always skip
_SKIP_TYPES = {"progress", "file-history-snapshot", "last-prompt", "queue-operation",
               "ai-title", "custom-title", "summary", "teleported-from",
               "teleport-skipped-branch"}


def find_transcript_path(conversation_id: str, work_dir: str = "") -> Path | None:
    """Find the JSONL transcript file for a conversation.

    Claude Code stores transcripts at:
    ~/.claude/projects/<mangled-work-dir>/<conversation-id>.jsonl

    The mangled dir replaces / with - (e.g. /home/zeul/.clawmux/sessions/af_sky
    becomes -home-zeul--clawmux-sessions-af-sky).
    """
    if not conversation_id:
        return None

    if not _CLAUDE_PROJECTS_DIR.exists():
        return None

    # If work_dir given, try the mangled path directly
    if work_dir:
        mangled = re.sub(r"[^a-zA-Z0-9-]", "-", work_dir)
        candidate = _CLAUDE_PROJECTS_DIR / mangled / f"{conversation_id}.jsonl"
        if candidate.exists():
            return candidate

    # Fallback: search all project dirs
    for project_dir in _CLAUDE_PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        candidate = project_dir / f"{conversation_id}.jsonl"
        if candidate.exists():
            return candidate

    return None


def read_transcript(conversation_id: str, work_dir: str = "",
                    limit: int = 50) -> list[dict]:
    """Parse a JSONL transcript and return displayable messages.

    Returns messages AFTER the last compact_boundary (if any), limited to
    the most recent `limit` entries. Each message has:
    - role: "user" or "assistant"
    - text: extracted text content
    - ts: unix timestamp
    - tool_calls: list of {name, input} for tool_use blocks (assistant only)
    - tool_results: list of {tool_use_id, content} for tool_result blocks (user only)
    - uuid: message UUID
    """
    path = find_transcript_path(conversation_id, work_dir)
    if not path:
        return []

    try:
        return _parse_jsonl(path, limit)
    except Exception as e:
        log.warning("Failed to parse transcript %s: %s", path, e)
        return []


def _parse_jsonl(path: Path, limit: int) -> list[dict]:
    """Parse the JSONL file, handling compact boundaries."""
    entries: list[dict] = []
    last_boundary_idx: int = -1

    with open(path) as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            entry_type = entry.get("type", "")
            subtype = entry.get("subtype", "")

            # Track compact boundaries — we'll discard everything before the last one
            if entry_type == "system" and subtype == "compact_boundary":
                last_boundary_idx = len(entries)
                entries.append({"_boundary": True})
                continue

            # Skip non-displayable types
            if entry_type in _SKIP_TYPES:
                continue
            if entry_type == "system":
                continue  # all system subtypes are hidden

            # Skip compact summary (the user entry right after boundary)
            if entry.get("isCompactSummary"):
                continue

            # Only keep user/assistant
            if entry_type not in _DISPLAY_TYPES:
                continue

            msg = entry.get("message", {})
            role = msg.get("role", entry_type)
            content = msg.get("content", [])

            # Skip catch-up context injections (internal prompt, not user message)
            if role == "user" and isinstance(content, list):
                first_text = next(
                    (b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text"), ""
                )
                if first_text.startswith("# Messages Since You Were Last Active"):
                    continue
                if first_text.startswith("Greet the user as instructed in your CLAUDE.md"):
                    continue

            # Pass through the full content block structure
            # Truncate large tool_result content to avoid huge payloads
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        rc = block.get("content", "")
                        if isinstance(rc, str) and len(rc) > 2000:
                            block["content"] = rc[:2000] + "…"
                        elif isinstance(rc, list):
                            for sub in rc:
                                if isinstance(sub, dict) and sub.get("type") == "text":
                                    t = sub.get("text", "")
                                    if len(t) > 2000:
                                        sub["text"] = t[:2000] + "…"

            # For assistant messages with only tool_use blocks (no text),
            # check if any Bash tool_use contains a clawmux send --to user command.
            # This extracts the spoken response from legacy sessions that used clawmux send.
            if role == "assistant" and isinstance(content, list):
                has_text = any(isinstance(b, dict) and b.get("type") == "text" for b in content)
                if not has_text:
                    for block in content:
                        if (isinstance(block, dict) and block.get("type") == "tool_use"
                                and block.get("name") == "Bash"):
                            cmd = block.get("input", {}).get("command", "")
                            spoken = _extract_clawmux_send_text(cmd)
                            if spoken:
                                content.append({"type": "text", "text": spoken})
                                break

            # Extract text for filtering decisions
            text = ""
            has_tool_result = False
            if isinstance(content, list):
                text = "".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                )
                has_tool_result = any(
                    isinstance(b, dict) and b.get("type") == "tool_result"
                    for b in content
                )
            elif isinstance(content, str):
                text = content

            # Keep user entries with tool_results (frontend needs them for tool cards)
            # Skip only if completely empty (no text AND no tool results)
            if role == "user" and not text and not has_tool_result:
                continue

            # Parse timestamp
            ts_str = entry.get("timestamp", "")
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
            except Exception:
                ts = 0

            parsed = {
                "role": role,
                "content": content,  # full Anthropic content block array
                "ts": ts,
                "uuid": entry.get("uuid", ""),
            }
            # Include text as convenience field for simple rendering
            if text:
                parsed["text"] = text
            # Include usage if present
            usage = msg.get("usage")
            if usage:
                parsed["usage"] = usage

            entries.append(parsed)

    # If there was a compact boundary, discard everything before it
    if last_boundary_idx >= 0:
        entries = entries[last_boundary_idx + 1:]

    # Remove boundary markers
    entries = [e for e in entries if not e.get("_boundary")]

    # Return last N messages
    return entries[-limit:]
