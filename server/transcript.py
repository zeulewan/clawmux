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

            # Extract text and tool blocks
            text_parts = []
            tool_calls = []
            tool_results = []

            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    block_type = block.get("type", "")
                    if block_type == "text":
                        text_parts.append(block.get("text", ""))
                    elif block_type == "tool_use":
                        tool_calls.append({
                            "id": block.get("id", ""),
                            "name": block.get("name", ""),
                            "input": block.get("input", {}),
                        })
                    elif block_type == "tool_result":
                        result_content = block.get("content", "")
                        if isinstance(result_content, list):
                            result_content = "".join(
                                b.get("text", "") for b in result_content
                                if isinstance(b, dict) and b.get("type") == "text"
                            )
                        tool_results.append({
                            "tool_use_id": block.get("tool_use_id", ""),
                            "content": str(result_content)[:500],
                        })
            elif isinstance(content, str):
                text_parts.append(content)

            text = "".join(text_parts)

            # Skip user entries that are only tool results with no text
            if role == "user" and not text and tool_results:
                continue

            # Skip assistant entries that are only tool calls with no text
            # (but include them in a summarized form)
            if role == "assistant" and not text and tool_calls:
                # Keep as tool-only message
                pass

            # Parse timestamp
            ts_str = entry.get("timestamp", "")
            try:
                ts = datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
            except Exception:
                ts = 0

            parsed = {
                "role": role,
                "text": text,
                "ts": ts,
                "uuid": entry.get("uuid", ""),
            }
            if tool_calls:
                parsed["tool_calls"] = tool_calls
            if tool_results:
                parsed["tool_results"] = tool_results

            entries.append(parsed)

    # If there was a compact boundary, discard everything before it
    if last_boundary_idx >= 0:
        entries = entries[last_boundary_idx + 1:]

    # Remove boundary markers
    entries = [e for e in entries if not e.get("_boundary")]

    # Return last N messages
    return entries[-limit:]
