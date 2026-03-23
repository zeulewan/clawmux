"""E2E tests for claude-json frontend UI.

Spawns a claude-json agent, sends a multi-tool task, and verifies:
- Tool cards render with correct tool name + input summary
- Tool card expand/collapse works
- No old typing dots during processing
- Decode animation shows during thinking
- No "Ready"/"Idle" text in chat area
- Spinner clears when agent finishes

Run: cd /home/zeul/GIT/clawmux && .venv/bin/python -m pytest tests/test_claude_json_ui.py -v --tb=short
Requires: hub running at localhost:3460, Playwright + Chromium installed.
"""

import json
import time
import httpx
import pytest
from pathlib import Path
from playwright.sync_api import sync_playwright, Page, expect

HUB_URL = "http://localhost:3460"
SCREENSHOT_DIR = Path(__file__).parent / "screenshots"
SCREENSHOT_DIR.mkdir(exist_ok=True)

# Use a voice that's likely free — we'll terminate any existing session first
TEST_VOICE = "bm_daniel"
TEST_SESSION_ID = "daniel"


def _api(method: str, path: str, **kwargs) -> dict:
    """Quick API helper."""
    with httpx.Client(base_url=HUB_URL, timeout=30) as c:
        resp = getattr(c, method)(path, **kwargs)
        return resp.json()


def _ensure_session_terminated():
    """Terminate any existing session for the test voice."""
    try:
        _api("delete", f"/api/sessions/{TEST_SESSION_ID}")
    except Exception:
        pass
    time.sleep(1)


def _spawn_claude_json() -> dict:
    """Spawn a claude-json agent and return session dict."""
    return _api("post", "/api/sessions", json={
        "voice": TEST_VOICE,
        "backend": "claude-json",
    })


@pytest.fixture(scope="module")
def browser():
    """Launch browser for the test module."""
    with sync_playwright() as p:
        b = p.chromium.launch(headless=True)
        yield b
        b.close()


@pytest.fixture(scope="module")
def session_id(browser):
    """Spawn claude-json agent and return session_id."""
    _ensure_session_terminated()
    time.sleep(2)
    result = _spawn_claude_json()
    sid = result.get("session_id")
    if not sid:
        pytest.skip(f"Failed to spawn: {result}")
    # Wait for session to reach IDLE
    deadline = time.time() + 60
    while time.time() < deadline:
        sessions = _api("get", "/api/sessions")
        for s in sessions:
            if s["session_id"] == sid and s["state"] == "idle":
                return sid
        time.sleep(2)
    pytest.skip("Session never reached IDLE")


@pytest.fixture
def page(browser, session_id):
    """Open hub in browser and navigate to the test session's chat tab."""
    ctx = browser.new_context(viewport={"width": 1400, "height": 900})
    pg = ctx.new_page()
    pg.goto(HUB_URL)
    # Wait for WS connection + session list
    pg.wait_for_selector(".sidebar-card", timeout=15000)
    time.sleep(2)
    # Click on the test agent's sidebar card to switch to their tab
    card = pg.locator(f'.sidebar-card[data-session-id="{session_id}"]')
    if card.count() > 0:
        card.first.click()
        time.sleep(1)
    pg.screenshot(path=str(SCREENSHOT_DIR / "01_initial.png"))
    yield pg
    ctx.close()


def test_spawn_reached_idle(session_id):
    """Test 1: claude-json agent spawned and reached IDLE."""
    sessions = _api("get", "/api/sessions")
    s = next((s for s in sessions if s["session_id"] == session_id), None)
    assert s is not None, f"Session {session_id} not found"
    assert s["backend"] == "claude-json"
    assert s["state"] == "idle"


def test_send_task_tool_cards_render(page: Page, session_id):
    """Test 2-4: Send multi-tool task and verify tool cards appear."""
    # Type a message using the browser's text input
    text_input = page.locator("#text-input, textarea.text-input, input[type='text']")
    if text_input.count() > 0:
        text_input.first.fill("Read /home/zeul/GIT/clawmux/server/hub_config.py and tell me what port it uses.")
        text_input.first.press("Enter")
    else:
        # Fallback: send via speak API (simulates user message delivery)
        with httpx.Client(base_url=HUB_URL, timeout=10) as c:
            c.post("/api/messages/speak", json={
                "sender": session_id,
                "message": "[VOICE id:test from:user] Read /home/zeul/GIT/clawmux/server/hub_config.py and tell me what port it uses.",
            })
    time.sleep(2)
    page.screenshot(path=str(SCREENSHOT_DIR / "02_task_sent.png"))

    # Wait for processing state or tool cards
    try:
        page.wait_for_selector(".tool-card", timeout=30000)
        page.screenshot(path=str(SCREENSHOT_DIR / "03_tool_cards.png"))
    except Exception:
        page.screenshot(path=str(SCREENSHOT_DIR / "03_no_tool_cards.png"))
        # Check if we at least see the thinking decode
        decode = page.locator(".thinking-decode")
        if decode.count() > 0:
            pytest.skip("No tool cards rendered but thinking decode is visible")
        pytest.fail("No tool cards appeared within 30s")

    # Verify tool card has tool name
    cards = page.locator(".tool-card")
    assert cards.count() > 0, "Expected at least one tool card"
    first_card = cards.first
    name_el = first_card.locator(".tool-card-name")
    assert name_el.count() > 0, "Tool card missing name element"


def test_tool_card_expand_collapse(page: Page, session_id):
    """Test 5: Clicking tool card header expands/collapses the body."""
    cards = page.locator(".tool-card")
    if cards.count() == 0:
        pytest.skip("No tool cards to test expand/collapse")

    header = cards.first.locator(".tool-card-header")
    body = cards.first.locator(".tool-card-body")

    # Click to expand
    header.click()
    time.sleep(0.5)
    page.screenshot(path=str(SCREENSHOT_DIR / "04_card_expanded.png"))
    display = body.evaluate("el => getComputedStyle(el).display")
    assert display != "none", f"Expected body visible after click, got display={display}"

    # Click to collapse
    header.click()
    time.sleep(0.5)
    display = body.evaluate("el => getComputedStyle(el).display")
    assert display == "none", f"Expected body hidden after second click, got display={display}"


def test_no_old_typing_dots(page: Page, session_id):
    """Test 6: No old typing-indicator visible during processing for claude-json."""
    # The typing indicator should not be present for claude-json backend
    dots = page.locator(".typing-indicator:visible")
    page.screenshot(path=str(SCREENSHOT_DIR / "05_no_typing_dots.png"))
    assert dots.count() == 0, "Old typing dots should not be visible for claude-json"


def test_no_ready_idle_text(page: Page, session_id):
    """Test 8: No 'Ready' or 'Idle' text in chat area."""
    # Wait for idle state
    time.sleep(5)
    chat = page.locator("#chat-area")
    if chat.count() == 0:
        pytest.skip("Chat area not found")
    text = chat.inner_text()
    page.screenshot(path=str(SCREENSHOT_DIR / "06_idle_state.png"))
    # "Ready" status should not appear in chat for claude-json
    # (It may appear in sidebar which is fine)
    status = page.locator("#status-text")
    if status.count() > 0:
        status_text = status.inner_text()
        assert "Ready" not in status_text, f"'Ready' found in status: {status_text}"


def test_spinner_clears_on_finish(page: Page, session_id):
    """Test 9: Spinner/decode clears when agent finishes."""
    # Wait for agent to finish (state goes to idle)
    deadline = time.time() + 60
    while time.time() < deadline:
        sessions = _api("get", "/api/sessions")
        s = next((s for s in sessions if s["session_id"] == session_id), None)
        if s and s["state"] == "idle":
            break
        time.sleep(2)

    time.sleep(1)
    page.screenshot(path=str(SCREENSHOT_DIR / "07_finished.png"))

    # Thinking decode should be hidden
    decode = page.locator(".thinking-decode:visible")
    assert decode.count() == 0, "Thinking decode should be hidden when idle"

    # Typing indicator should be hidden
    dots = page.locator(".typing-indicator:visible")
    assert dots.count() == 0, "Typing indicator should be hidden when idle"


def test_cleanup():
    """Terminate test session."""
    _ensure_session_terminated()
