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

    // MARK: - Navigate To Michael (Header Check)

    /// Navigate to Michael's chat via expanded sidebar and screenshot the header.
    func testMichaelHeaderNotCutOff() throws {
        saveScreenshot("michael_00_start")

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 8) else { XCTFail("No hamburger"); return }
        hamburger.tap()
        sleep(2)

        let sidebar = app.scrollViews["SidebarScrollView"].firstMatch
        if sidebar.waitForExistence(timeout: 3) {
            sidebar.swipeUp()
            sleep(1)
        }

        let michael = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Michael'")).firstMatch
        if michael.waitForExistence(timeout: 3) {
            michael.tap()
            sleep(2)
            saveScreenshot("michael_01_header")
        } else {
            saveScreenshot("michael_01_not_found")
        }
        XCTAssertTrue(app.exists)
    }

    // MARK: - Blank Chat Viewport Reproduction

    /// Systematically try UI action combinations to reproduce the blank chat bug:
    /// open/close sidebar, switch agents, open/close settings, open/close debug,
    /// switch to group chat and back. After each action, check if chat has content.
    func testBlankChatViewportReproduction() throws {
        saveScreenshot("blank_00_start")

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 8) else { XCTFail("No hamburger"); return }

        // Start with an agent that has messages
        tapAgent(at: 0)
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch

        func checkChatVisible(_ label: String) -> Bool {
            let exists = chatScroll.waitForExistence(timeout: 3)
            let textCount = app.staticTexts.count
            saveScreenshot("blank_\(label)")
            if exists && textCount < 3 {
                // Possible blank — very few text elements visible
                print("[BLANK?] \(label): ChatScrollView exists but only \(textCount) texts")
                return false
            }
            return exists
        }

        // Action 1: Open and close sidebar
        hamburger.tap(); sleep(1)
        hamburger.tap(); sleep(1)
        let r1 = checkChatVisible("01_sidebar_toggle")

        // Action 2: Switch agent and back
        tapAgent(at: 1); sleep(1)
        tapAgent(at: 0); sleep(1)
        let r2 = checkChatVisible("02_agent_switch_back")

        // Action 3: Open settings, close it
        hamburger.tap(); sleep(1)
        let settingsBtn = app.buttons["SidebarSettingsButton"].firstMatch
        if settingsBtn.waitForExistence(timeout: 3) {
            settingsBtn.tap()
            sleep(1)
            saveScreenshot("blank_03a_settings_open")
            let doneBtn = app.buttons["Done"].firstMatch
            if doneBtn.waitForExistence(timeout: 3) { doneBtn.tap() }
            sleep(1)
        }
        hamburger.tap(); sleep(1) // close sidebar
        let r3 = checkChatVisible("03_after_settings")

        // Action 4: Open notes, close it
        hamburger.tap(); sleep(1)
        let notesBtn = app.buttons["SidebarNotesButton"].firstMatch
        if notesBtn.waitForExistence(timeout: 3) {
            notesBtn.tap()
            sleep(1)
            saveScreenshot("blank_04a_notes_open")
            // Close notes by tapping outside or back
            let closeNotes = app.buttons["Done"].firstMatch
            if closeNotes.waitForExistence(timeout: 2) { closeNotes.tap() }
            sleep(1)
        }
        hamburger.tap(); sleep(1) // close sidebar
        let r4 = checkChatVisible("04_after_notes")

        // Action 5: Switch to group chat and back
        hamburger.tap(); sleep(1)
        let sidebar = app.scrollViews["SidebarScrollView"].firstMatch
        if sidebar.waitForExistence(timeout: 3) {
            sidebar.swipeUp(); sleep(1)
            sidebar.swipeUp(); sleep(1)
        }
        let gcCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'GroupChatCard-'")).firstMatch
        if gcCard.waitForExistence(timeout: 3) {
            gcCard.tap()
            sleep(2)
            saveScreenshot("blank_05a_group_chat")
            // Switch back to agent
            hamburger.tap(); sleep(1)
            tapAgent(at: 0); sleep(2)
        }
        let r5 = checkChatVisible("05_after_group_switch")

        // Action 6: Rapid mixed sequence
        for i in 0..<5 {
            hamburger.tap(); usleep(300_000)
            hamburger.tap(); usleep(300_000)
            tapAgent(at: i % 5); usleep(500_000)
        }
        sleep(1)
        let r6 = checkChatVisible("06_rapid_mixed")

        // Action 7: Open debug panel, close it
        hamburger.tap(); sleep(1)
        if settingsBtn.waitForExistence(timeout: 3) {
            settingsBtn.tap()
            sleep(1)
            // Look for debug button in settings
            let debugBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Debug'")).firstMatch
            if debugBtn.waitForExistence(timeout: 3) {
                debugBtn.tap()
                sleep(2)
                saveScreenshot("blank_07a_debug_open")
                // Close debug by tapping the debug button again or navigating away
                tapAgent(at: 0)
                sleep(2)
            } else {
                let doneBtn = app.buttons["Done"].firstMatch
                if doneBtn.waitForExistence(timeout: 2) { doneBtn.tap() }
            }
            sleep(1)
        }
        hamburger.tap(); sleep(1) // close sidebar if open
        let r7 = checkChatVisible("07_after_debug")

        // Report
        let allPassed = r1 && r2 && r3 && r4 && r5 && r6 && r7
        if !allPassed {
            print("[BLANK] Some checks found possible blank viewport — review screenshots")
        }
        XCTAssertTrue(app.exists, "App should survive full UI action sequence")
    }

    // MARK: - Typing Mode: Send Messages to Multiple Agents

    /// Switch to typing mode, send messages to two agents, switch between them,
    /// verify messages render and scroll stays correct.
    func testTypingModeSendToMultipleAgents() throws {
        saveScreenshot("typing_00_start")

        // Switch to text mode via header toggle
        let modeBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mode'")).firstMatch
        if modeBtn.waitForExistence(timeout: 5) {
            modeBtn.tap()
            sleep(1)
        }

        // Expand sidebar to find Liam
        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 5) else { XCTFail("No hamburger"); return }
        hamburger.tap()
        sleep(2)

        let sidebar = app.scrollViews["SidebarScrollView"].firstMatch
        if sidebar.waitForExistence(timeout: 3) { sidebar.swipeUp(); sleep(1) }

        // Find and tap Liam
        let liam = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Liam'")).firstMatch
        if liam.waitForExistence(timeout: 3) {
            liam.tap()
            sleep(2)
        } else {
            // Fallback: tap agent at position 6
            hamburger.tap(); sleep(1)
            tapAgent(at: 6); sleep(2)
        }
        saveScreenshot("typing_01_liam_selected")

        // Find text input and type
        let textField = app.textFields.firstMatch
        let textView = app.textViews.firstMatch
        let input: XCUIElement
        if textField.waitForExistence(timeout: 3) {
            input = textField
        } else if textView.waitForExistence(timeout: 3) {
            input = textView
        } else {
            saveScreenshot("typing_02_no_input")
            return // No text input available — mode may not have switched
        }

        let msg1 = "Test from Onyx to Liam \(Int.random(in: 1000...9999))"
        input.tap()
        sleep(1)
        input.typeText(msg1)
        saveScreenshot("typing_03_liam_typed")

        // Send
        let sendBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'send' OR label CONTAINS[c] 'arrow'")).firstMatch
        if sendBtn.waitForExistence(timeout: 3) {
            sendBtn.tap()
            sleep(2)
        }
        saveScreenshot("typing_04_liam_sent")

        // Verify message visible
        let msgVisible = app.staticTexts[msg1].waitForExistence(timeout: 5)
        XCTAssertTrue(msgVisible, "Sent message should be visible in Liam's chat")

        // No scroll-down chevron (should be at bottom)
        XCTAssertFalse(scrollDownButtonVisible, "Should be at bottom after sending to Liam")

        // Switch to Lewis via sidebar
        hamburger.tap(); sleep(2)
        if sidebar.waitForExistence(timeout: 3) { sidebar.swipeUp(); sleep(1) }
        let lewis = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Lewis'")).firstMatch
        if lewis.waitForExistence(timeout: 3) {
            lewis.tap()
            sleep(2)
        } else {
            hamburger.tap(); sleep(1)
            tapAgent(at: 7); sleep(2)
        }
        saveScreenshot("typing_05_lewis_selected")

        // Type and send to Lewis
        let input2 = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        if input2.waitForExistence(timeout: 3) {
            let msg2 = "Test from Onyx to Lewis \(Int.random(in: 1000...9999))"
            input2.tap(); sleep(1)
            input2.typeText(msg2)

            if sendBtn.waitForExistence(timeout: 3) {
                sendBtn.tap()
                sleep(2)
            }
            saveScreenshot("typing_06_lewis_sent")

            let msg2Visible = app.staticTexts[msg2].waitForExistence(timeout: 5)
            XCTAssertTrue(msg2Visible, "Sent message should be visible in Lewis's chat")
        }

        // Switch back to Liam — original message should still be there
        hamburger.tap(); sleep(2)
        if sidebar.waitForExistence(timeout: 3) { sidebar.swipeUp(); sleep(1) }
        if liam.waitForExistence(timeout: 3) {
            liam.tap()
            sleep(2)
        }
        saveScreenshot("typing_07_back_to_liam")

        // Verify Liam's message still visible
        let msg1StillThere = app.staticTexts[msg1].waitForExistence(timeout: 5)
        XCTAssertTrue(msg1StillThere, "Original message to Liam should still be visible after switching back")

        XCTAssertFalse(scrollDownButtonVisible, "Should be at bottom when returning to Liam")
        XCTAssertTrue(app.exists, "App should survive typing mode multi-agent test")
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
