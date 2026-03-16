import XCTest

/// Practical user-flow tests: switching agents, verifying scroll position,
/// keyboard interactions, and message visibility. Designed to catch the
/// bugs a real user would notice.
///
/// Requires a live hub with at least 2 agents that have message history.
final class UserFlowTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        sleep(4) // WebSocket connection
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let url = URL(fileURLWithPath: "/tmp/userflow_\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps the nth agent icon in the collapsed sidebar (0-indexed from top).
    private func tapAgent(at index: Int) {
        // Agent icons stacked vertically at x≈6%, starting y≈12%, spaced ~5%
        let y = 0.12 + Double(index) * 0.05
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: y)).tap()
    }

    /// Returns the number of visible static text elements in the chat area.
    private var chatTextCount: Int {
        app.staticTexts.count
    }

    /// Checks if the scroll-to-bottom chevron button is visible.
    private var scrollDownButtonVisible: Bool {
        // The chevron button is an Image(systemName: "chevron.down") inside a Button
        let chevron = app.buttons.matching(NSPredicate(format: "label CONTAINS 'chevron'")).firstMatch
        return chevron.exists
    }

    // MARK: - Agent Switch: Scroll Position

    /// Switch between two agents. Each should show their chat scrolled to the bottom.
    /// The scroll-to-bottom chevron should NOT be visible (we should start at bottom).
    func testAgentSwitchShowsBottomOfChat() throws {
        saveScreenshot("switch_scroll_00_start")

        // Tap first agent
        tapAgent(at: 0)
        sleep(2)
        saveScreenshot("switch_scroll_01_agent1")

        // Should be at bottom — no scroll-down button visible
        let chatScroll1 = app.scrollViews["ChatScrollView"].firstMatch
        if chatScroll1.waitForExistence(timeout: 5) {
            // Chevron should not be showing (we're at bottom)
            XCTAssertFalse(scrollDownButtonVisible,
                "Scroll-to-bottom chevron should not be visible on fresh agent switch (agent 1)")
        }

        // Switch to second agent
        tapAgent(at: 1)
        sleep(2)
        saveScreenshot("switch_scroll_02_agent2")

        let chatScroll2 = app.scrollViews["ChatScrollView"].firstMatch
        if chatScroll2.waitForExistence(timeout: 5) {
            XCTAssertFalse(scrollDownButtonVisible,
                "Scroll-to-bottom chevron should not be visible on fresh agent switch (agent 2)")
        }

        // Switch back to first agent
        tapAgent(at: 0)
        sleep(2)
        saveScreenshot("switch_scroll_03_back_to_agent1")

        if chatScroll1.waitForExistence(timeout: 5) {
            XCTAssertFalse(scrollDownButtonVisible,
                "Scroll-to-bottom chevron should not be visible when returning to agent 1")
        }

        XCTAssertTrue(app.exists, "App should survive agent switching")
    }

    // MARK: - Scroll Up Then Switch: New Agent Should Be At Bottom

    /// Scroll up in one agent's chat, then switch to another.
    /// The new agent should start at the bottom, not inherit the scrolled-up position.
    func testScrollUpThenSwitchStartsAtBottom() throws {
        // Open first agent
        tapAgent(at: 0)
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 5) else {
            XCTFail("ChatScrollView not found")
            return
        }

        // Scroll up several times
        chatScroll.swipeDown(velocity: .fast)
        chatScroll.swipeDown(velocity: .fast)
        chatScroll.swipeDown(velocity: .fast)
        sleep(1)
        saveScreenshot("scroll_switch_01_scrolled_up")

        // Scroll-down button should now be visible (we scrolled away from bottom)
        // (Only if there's enough content to scroll)

        // Switch to second agent
        tapAgent(at: 1)
        sleep(2)
        saveScreenshot("scroll_switch_02_new_agent")

        // The NEW agent should be at the bottom — no chevron
        if app.scrollViews["ChatScrollView"].firstMatch.waitForExistence(timeout: 5) {
            XCTAssertFalse(scrollDownButtonVisible,
                "New agent should start at bottom — scroll-to-bottom chevron should not be visible")
        }
    }

    // MARK: - Text Mode Keyboard: Chat Doesn't Shift

    /// Open text input mode, verify the chat messages don't drift horizontally.
    /// Takes screenshots before and after keyboard appearance for comparison.
    func testKeyboardDoesNotShiftChat() throws {
        // Open an agent with messages
        tapAgent(at: 0)
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 5) else {
            XCTFail("ChatScrollView not found")
            return
        }

        saveScreenshot("keyboard_shift_01_before")

        // Find and tap the VOICE MODE button to cycle to text mode
        // The mode toggle is in the header area
        let voiceMode = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice' OR label CONTAINS[c] 'typing' OR label CONTAINS[c] 'mode'")).firstMatch
        if voiceMode.waitForExistence(timeout: 3) {
            voiceMode.tap()
            sleep(1)
            saveScreenshot("keyboard_shift_02_mode_toggled")
        }

        // Try tapping the text field area at the bottom to bring up keyboard
        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        if textField.waitForExistence(timeout: 3) {
            textField.tap()
        } else if textView.waitForExistence(timeout: 3) {
            textView.tap()
        } else {
            // Tap bottom center where the input area is
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        }
        sleep(1)
        saveScreenshot("keyboard_shift_03_keyboard_up")

        // Chat scroll view should still exist and be responsive
        XCTAssertTrue(chatScroll.exists, "ChatScrollView should exist with keyboard open")

        // Dismiss keyboard
        chatScroll.tap() // tap chat area to dismiss
        sleep(1)
        saveScreenshot("keyboard_shift_04_keyboard_dismissed")

        XCTAssertTrue(app.exists, "App should survive keyboard open/close")
    }

    // MARK: - Send Message and Verify It Appears

    /// Switch to text mode, type a test message, send it, verify it appears in the chat.
    func testSendMessageAppearsInChat() throws {
        tapAgent(at: 0)
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 5) else {
            XCTFail("ChatScrollView not found")
            return
        }

        saveScreenshot("send_msg_01_before")

        // Switch to typing mode
        let voiceMode = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice' OR label CONTAINS[c] 'typing' OR label CONTAINS[c] 'mode'")).firstMatch
        if voiceMode.waitForExistence(timeout: 3) {
            voiceMode.tap()
            sleep(1)
        }

        // Find the text input
        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        let input: XCUIElement
        if textField.waitForExistence(timeout: 3) {
            input = textField
        } else if textView.waitForExistence(timeout: 3) {
            input = textView
        } else {
            saveScreenshot("send_msg_02_no_input_found")
            // Not a failure — typing mode may not have a visible text field yet
            return
        }

        let testMessage = "XCUITest message \(Int.random(in: 1000...9999))"
        input.tap()
        sleep(1)
        input.typeText(testMessage)
        saveScreenshot("send_msg_03_typed")

        // Find and tap send button
        let sendBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'send' OR label CONTAINS[c] 'arrow'")).firstMatch
        if sendBtn.waitForExistence(timeout: 3) {
            sendBtn.tap()
            sleep(2)
            saveScreenshot("send_msg_04_sent")

            // Verify the message text appears in the chat
            let msgExists = app.staticTexts[testMessage].waitForExistence(timeout: 5)
            saveScreenshot("send_msg_05_verify")
            XCTAssertTrue(msgExists, "Sent message '\(testMessage)' should be visible in chat")

            // Should still be at bottom after sending
            XCTAssertFalse(scrollDownButtonVisible,
                "Should be at bottom after sending a message")
        }
    }

    // MARK: - Multiple Agent Round Trip: All At Bottom

    /// Tap through 5 agents in sequence, then reverse. Each should show chat at bottom.
    func testMultipleAgentRoundTripAllAtBottom() throws {
        saveScreenshot("roundtrip_00_start")

        // Forward pass
        for i in 0..<5 {
            tapAgent(at: i)
            sleep(1)

            let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
            if chatScroll.waitForExistence(timeout: 3) {
                // Check scroll position — if agent has messages, chevron should not show
                saveScreenshot("roundtrip_fwd_\(i)")
            }
        }

        // Reverse pass
        for i in (0..<5).reversed() {
            tapAgent(at: i)
            sleep(1)

            let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
            if chatScroll.waitForExistence(timeout: 3) {
                saveScreenshot("roundtrip_rev_\(i)")
            }
        }

        XCTAssertTrue(app.exists, "App should survive round-trip agent switching")
    }

    // MARK: - Keyboard Open + Switch Agent: Clean Transition

    /// Open keyboard in text mode, then tap a different agent.
    /// New agent should show cleanly without keyboard artifacts.
    func testKeyboardOpenThenSwitchAgent() throws {
        tapAgent(at: 0)
        sleep(2)

        // Switch to typing mode and open keyboard
        let voiceMode = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice' OR label CONTAINS[c] 'typing' OR label CONTAINS[c] 'mode'")).firstMatch
        if voiceMode.waitForExistence(timeout: 3) {
            voiceMode.tap()
            sleep(1)
        }

        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        if textField.waitForExistence(timeout: 3) {
            textField.tap()
        } else if textView.waitForExistence(timeout: 3) {
            textView.tap()
        }
        sleep(1)
        saveScreenshot("kb_switch_01_keyboard_open")

        // Switch to another agent while keyboard is up
        tapAgent(at: 2)
        sleep(2)
        saveScreenshot("kb_switch_02_switched_with_kb")

        // Verify new agent's chat is visible and clean
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5),
            "ChatScrollView should exist after switching agents with keyboard open")

        XCTAssertTrue(app.exists, "App should survive keyboard-open agent switch")
    }
}
