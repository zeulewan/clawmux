"""In-memory message broker for inter-agent communication.

Tracks messages by ID through lifecycle states:
    pending → acknowledged → responded → failed

Messages are injected into tmux panes via tmux send-keys.
The broker handles acknowledgment routing, response routing,
and retry logic for unacknowledged messages.
"""

import asyncio
import hashlib
import logging
import subprocess
import time
from dataclasses import dataclass, field

log = logging.getLogger("voice-hub.broker")

# Message lifecycle states
PENDING = "pending"
ACKNOWLEDGED = "acknowledged"
RESPONDED = "responded"
FAILED = "failed"

# Retry config
MAX_RETRIES = 3
RETRY_INTERVAL = 60  # seconds
ACK_TIMEOUT = 180  # seconds before marking as failed


@dataclass
class Message:
    id: str
    sender: str           # session_id of sender
    recipient: str        # session_id of recipient
    content: str
    expect_response: bool = False
    state: str = PENDING
    created_at: float = 0
    acked_at: float = 0
    responded_at: float = 0
    response_text: str = ""
    retry_count: int = 0
    last_retry_at: float = 0
    sender_name: str = ""
    recipient_name: str = ""

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "sender": self.sender,
            "recipient": self.recipient,
            "sender_name": self.sender_name,
            "recipient_name": self.recipient_name,
            "content": self.content,
            "expect_response": self.expect_response,
            "state": self.state,
            "created_at": self.created_at,
            "acked_at": self.acked_at if self.acked_at else None,
            "responded_at": self.responded_at if self.responded_at else None,
            "response_text": self.response_text if self.response_text else None,
            "retry_count": self.retry_count,
        }


class MessageBroker:
    def __init__(self):
        self.messages: dict[str, Message] = {}
        # Waiters: message_id -> asyncio.Event for blocking send modes
        self._ack_waiters: dict[str, asyncio.Event] = {}
        self._response_waiters: dict[str, asyncio.Event] = {}
        self._retry_task = None

    def start(self):
        """Start the retry background loop."""
        if self._retry_task is None:
            self._retry_task = asyncio.create_task(self._retry_loop())

    def stop(self):
        """Stop the retry loop."""
        if self._retry_task:
            self._retry_task.cancel()
            self._retry_task = None

    def generate_id(self, sender: str, recipient: str) -> str:
        """Generate a unique message ID."""
        h = hashlib.sha256(f"{time.time()}{sender}{recipient}".encode()).hexdigest()[:8]
        return f"msg-{h}"

    async def send(
        self,
        sender: str,
        recipient: str,
        content: str,
        recipient_tmux: str,
        sender_name: str = "",
        recipient_name: str = "",
        expect_response: bool = False,
        skip_tmux: bool = False,
    ) -> Message:
        """Send a message. Injects into tmux unless skip_tmux=True (converse pipeline used instead)."""
        msg_id = self.generate_id(sender, recipient)
        msg = Message(
            id=msg_id,
            sender=sender,
            recipient=recipient,
            content=content,
            expect_response=expect_response,
            created_at=time.time(),
            sender_name=sender_name,
            recipient_name=recipient_name,
        )
        self.messages[msg_id] = msg

        # Create waiters
        self._ack_waiters[msg_id] = asyncio.Event()
        if expect_response:
            self._response_waiters[msg_id] = asyncio.Event()

        # Inject into tmux (skip if caller will use converse pipeline instead)
        if not skip_tmux:
            self._inject(msg, recipient_tmux, sender_name, recipient_name)

        log.info("Message %s: %s → %s (%s)", msg_id, sender, recipient,
                 "expect-response" if expect_response else "fire-and-forget")
        return msg

    def _inject(self, msg: Message, tmux_session: str, sender_name: str, recipient_name: str):
        """Inject a message into a tmux pane via send-keys."""
        expect = " expect-response" if msg.expect_response else ""
        formatted = f"[MSG id:{msg.id} from:{sender_name} to:{recipient_name}{expect}] {msg.content}"

        # Escape special characters for tmux
        escaped = (formatted
                   .replace("\\", "\\\\")
                   .replace('"', '\\"')
                   .replace("$", "\\$")
                   .replace("`", "\\`"))

        result = subprocess.run(
            ["tmux", "send-keys", "-t", tmux_session, escaped, "Enter"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            log.error("tmux inject failed for %s: %s", msg.id, result.stderr.strip())
        msg.last_retry_at = time.time()

    def acknowledge(self, msg_id: str) -> bool:
        """Mark a message as acknowledged. Returns True if found."""
        msg = self.messages.get(msg_id)
        if not msg:
            return False
        if msg.state != PENDING:
            return False
        msg.state = ACKNOWLEDGED
        msg.acked_at = time.time()
        log.info("Message %s acknowledged", msg_id)

        # Wake up ack waiter
        waiter = self._ack_waiters.pop(msg_id, None)
        if waiter:
            waiter.set()
        return True

    def reply(self, msg_id: str, response_text: str) -> bool:
        """Record a reply to a message. Returns True if found."""
        msg = self.messages.get(msg_id)
        if not msg:
            return False
        # Auto-ack if not yet acknowledged
        if msg.state == PENDING:
            msg.state = ACKNOWLEDGED
            msg.acked_at = time.time()
            waiter = self._ack_waiters.pop(msg_id, None)
            if waiter:
                waiter.set()

        msg.state = RESPONDED
        msg.responded_at = time.time()
        msg.response_text = response_text
        log.info("Message %s replied: %s", msg_id, response_text[:100])

        # Wake up response waiter
        waiter = self._response_waiters.pop(msg_id, None)
        if waiter:
            waiter.set()
        return True

    async def wait_for_ack(self, msg_id: str, timeout: float = 30) -> bool:
        """Wait for a message to be acknowledged. Returns True if acked."""
        waiter = self._ack_waiters.get(msg_id)
        if not waiter:
            return False
        try:
            await asyncio.wait_for(waiter.wait(), timeout=timeout)
            return True
        except asyncio.TimeoutError:
            return False

    async def wait_for_response(self, msg_id: str, timeout: float = 120) -> str | None:
        """Wait for a response to a message. Returns response text or None on timeout."""
        waiter = self._response_waiters.get(msg_id)
        if not waiter:
            return None
        try:
            await asyncio.wait_for(waiter.wait(), timeout=timeout)
            msg = self.messages.get(msg_id)
            return msg.response_text if msg else None
        except asyncio.TimeoutError:
            return None

    def get_message(self, msg_id: str) -> Message | None:
        return self.messages.get(msg_id)

    def get_pending_for(self, session_id: str) -> list[Message]:
        """Get all pending messages for a session."""
        return [
            m for m in self.messages.values()
            if m.recipient == session_id and m.state == PENDING
        ]

    def get_messages_for(self, session_id: str, limit: int = 20) -> list[Message]:
        """Get recent messages involving a session (sent or received)."""
        msgs = [
            m for m in self.messages.values()
            if m.sender == session_id or m.recipient == session_id
        ]
        msgs.sort(key=lambda m: m.created_at, reverse=True)
        return msgs[:limit]

    def list_all(self) -> list[dict]:
        """List all messages as dicts."""
        return [m.to_dict() for m in sorted(
            self.messages.values(), key=lambda m: m.created_at, reverse=True
        )]

    async def _retry_loop(self):
        """Background loop to retry unacknowledged messages."""
        while True:
            await asyncio.sleep(30)
            now = time.time()
            for msg in list(self.messages.values()):
                if msg.state != PENDING:
                    continue

                age = now - msg.created_at
                since_retry = now - msg.last_retry_at

                # Mark as failed after too many retries or too old
                if msg.retry_count >= MAX_RETRIES or age > ACK_TIMEOUT:
                    msg.state = FAILED
                    log.warning("Message %s failed after %d retries", msg.id, msg.retry_count)
                    # Clean up waiters
                    self._ack_waiters.pop(msg.id, None)
                    waiter = self._response_waiters.pop(msg.id, None)
                    if waiter:
                        waiter.set()  # Unblock with no response
                    continue

                # Retry if enough time has passed
                if since_retry >= RETRY_INTERVAL:
                    msg.retry_count += 1
                    log.info("Retrying message %s (attempt %d)", msg.id, msg.retry_count)
                    # Re-inject — need tmux session name
                    # We'll skip retry injection for now since we need session manager reference
                    # TODO: Add session lookup for retry injection
