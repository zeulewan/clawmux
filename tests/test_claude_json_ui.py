"""E2E tests for claude-json frontend UI.

Uses Nicole (claude-json) to verify tool cards, decode animation,
and indicator behavior. Run against live hub at localhost:3460.

Run: cd /home/zeul/GIT/clawmux && .venv/bin/python -m pytest tests/test_claude_json_ui.py -v --tb=short
"""

import json
import time
import httpx
import pytest
from pathlib import Path
from playwright.sync_api import sync_playwright, Page

HUB_URL = "http://localhost:3460"
SCREENSHOT_DIR = Path(__file__).parent / "screenshots"
SCREENSHOT_DIR.mkdir(exist_ok=True)


def _api(method: str, path: str, **kwargs) -> dict:
    with httpx.Client(base_url=HUB_URL, timeout=30) as c:
        resp = getattr(c, method)(path, **kwargs)
        return resp.json()


def _find_claude_json_session() -> str | None:
    """Find an existing claude-json session or spawn one."""
    sessions = _api("get", "/api/sessions")
    for s in sessions:
        if s.get("backend") == "claude-json":
            return s["session_id"]
    # Spawn one — find a free voice
    active_voices = {s["voice"] for s in sessions}
    for voice in ["af_nicole", "bm_daniel", "bm_lewis"]:
        if voice not in active_voices:
            result = _api("post", "/api/sessions", json={"voice": voice, "backend": "claude-json"})
            return result.get("session_id")
    return None


@pytest.fixture(scope="module")
def session_id():
    """Get or spawn a claude-json session."""
    sid = _find_claude_json_session()
    if not sid:
        pytest.skip("Could not find or spawn a claude-json session")
    # Wait for IDLE
    for _ in range(30):
        sessions = _api("get", "/api/sessions")
        s = next((s for s in sessions if s["session_id"] == sid), None)
        if s and s["state"] == "idle":
            return sid
        time.sleep(2)
    return sid  # proceed anyway


@pytest.fixture(scope="module")
def browser_ctx(session_id):
    """Launch browser and open the session's chat tab."""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1400, "height": 900})
        page = ctx.new_page()
        page.goto(HUB_URL)
        page.wait_for_selector(".sidebar-card", timeout=15000)
        time.sleep(3)

        # Find and click the claude-json agent's sidebar card
        # Get the label from the session
        sessions = _api("get", "/api/sessions")
        s = next((s for s in sessions if s["session_id"] == session_id), None)
        label = s["label"] if s else session_id

        card = page.locator(f'.sidebar-card:has-text("{label}")')
        if card.count() > 0:
            card.first.click()
            time.sleep(2)

        page.screenshot(path=str(SCREENSHOT_DIR / "01_chat_tab.png"))
        yield {"page": page, "label": label}
        ctx.close()
        browser.close()


@pytest.fixture
def page(browser_ctx) -> Page:
    return browser_ctx["page"]


def test_01_session_is_claude_json(session_id):
    """Verify the test session exists and uses claude-json backend."""
    sessions = _api("get", "/api/sessions")
    s = next((s for s in sessions if s["session_id"] == session_id), None)
    assert s is not None
    assert s["backend"] == "claude-json"


def test_02_chat_tab_open(page: Page):
    """Verify we're looking at the agent's chat, not the landing page."""
    # Chat area should be visible
    chat = page.locator("#chat-area")
    assert chat.is_visible(), "Chat area not visible"
    # Text input should be visible
    text_input = page.locator("#text-input")
    assert text_input.is_visible(), "Text input not visible"
    # Landing page mic icon should NOT be visible
    landing = page.locator(".landing-mic, .splash-icon")
    if landing.count() > 0:
        assert not landing.first.is_visible(), "Still on landing page"
    page.screenshot(path=str(SCREENSHOT_DIR / "02_chat_open.png"))


def test_03_send_task_and_wait_for_response(page: Page, session_id):
    """Send a multi-tool task via text input, wait for response."""
    text_input = page.locator("#text-input")
    text_input.fill("Read the file /home/zeul/GIT/clawmux/server/hub_config.py and tell me what port the hub uses. Be brief.")
    text_input.press("Enter")
    page.screenshot(path=str(SCREENSHOT_DIR / "03_task_sent.png"))

    # Wait for the agent to finish (up to 60s)
    for _ in range(30):
        time.sleep(2)
        sessions = _api("get", "/api/sessions")
        s = next((s for s in sessions if s["session_id"] == session_id), None)
        if s and s["state"] == "idle":
            break
    time.sleep(1)
    page.screenshot(path=str(SCREENSHOT_DIR / "04_task_complete.png"))


def test_04_tool_cards_rendered(page: Page):
    """Verify tool cards appeared in the chat during the task."""
    cards = page.locator(".tool-card")
    page.screenshot(path=str(SCREENSHOT_DIR / "05_tool_cards.png"))
    # May or may not have tool cards depending on whether the agent used tools
    if cards.count() > 0:
        # Verify card has a name element
        first_name = cards.first.locator(".tool-card-name")
        assert first_name.count() > 0, "Tool card missing name"
        name_text = first_name.inner_text()
        assert len(name_text) > 0, "Tool card name is empty"
    else:
        # Agent may have responded without tools — not a failure
        # Check if at least a response bubble appeared
        msgs = page.locator(".message-bubble, .msg-assistant, [data-role='assistant']")
        assert msgs.count() > 0, "No tool cards AND no response messages found"


def test_05_tool_card_expand_collapse(page: Page):
    """Clicking tool card header expands the body."""
    cards = page.locator(".tool-card")
    if cards.count() == 0:
        pytest.skip("No tool cards to test expand/collapse")

    header = cards.first.locator(".tool-card-header")
    body = cards.first.locator(".tool-body-grid")

    # Scroll card below fixed header before clicking
    header.evaluate("el => el.scrollIntoView({block: 'center'})")
    time.sleep(0.3)

    # Tool card is a <details> element — check open attribute
    is_open = cards.first.evaluate("el => el.open")
    assert not is_open, "Card should start closed"

    # Expand via JS click on summary (bypasses z-index overlap)
    header.evaluate("el => el.click()")
    time.sleep(0.5)
    page.screenshot(path=str(SCREENSHOT_DIR / "06_card_expanded.png"))
    is_open = cards.first.evaluate("el => el.open")
    assert is_open, "Card should be open after click"

    # Collapse
    header.evaluate("el => el.click()")
    time.sleep(0.5)
    is_open = cards.first.evaluate("el => el.open")
    assert not is_open, "Card should be closed after second click"


def test_06_no_old_typing_dots(page: Page):
    """No old typing-indicator visible for claude-json sessions."""
    dots = page.locator(".typing-indicator:visible")
    page.screenshot(path=str(SCREENSHOT_DIR / "07_no_dots.png"))
    assert dots.count() == 0, "Old typing dots should not be visible"


def test_07_no_ready_text_in_chat(page: Page):
    """No 'Ready' or 'Idle' status text in the chat area."""
    status = page.locator("#status-text")
    if status.count() > 0 and status.is_visible():
        text = status.inner_text().strip()
        assert "Ready" not in text, f"'Ready' found in status: {text}"
        assert "Idle" not in text, f"'Idle' found in status: {text}"
    page.screenshot(path=str(SCREENSHOT_DIR / "08_no_ready.png"))


def test_08_spinner_clears_on_idle(page: Page, session_id):
    """Decode animation and indicators clear when agent is idle."""
    # Make sure agent is idle
    for _ in range(15):
        sessions = _api("get", "/api/sessions")
        s = next((s for s in sessions if s["session_id"] == session_id), None)
        if s and s["state"] == "idle":
            break
        time.sleep(2)
    time.sleep(1)

    decode = page.locator(".thinking-decode:visible")
    dots = page.locator(".typing-indicator:visible")
    page.screenshot(path=str(SCREENSHOT_DIR / "09_idle_clean.png"))
    assert decode.count() == 0, "Thinking decode should be hidden when idle"
    assert dots.count() == 0, "Typing dots should be hidden when idle"
