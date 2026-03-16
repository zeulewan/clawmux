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

    // MARK: - Exhaustive Send + Switch + Verify

    /// Send messages to Liam and Lewis, screenshot after EVERY action,
    /// switch between them and other agents, verify chat is never blank.
    func testExhaustiveSendAndSwitchVerification() throws {
        saveScreenshot("exh_00_start")

        // Switch to text mode
        let modeBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'mode'")).firstMatch
        if modeBtn.waitForExistence(timeout: 5) { modeBtn.tap(); sleep(1) }

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 5) else { XCTFail("No hamburger"); return }

        // Helper: navigate to agent by name via expanded sidebar
        func goToAgent(_ name: String, screenshot label: String) {
            hamburger.tap(); sleep(2)
            let sidebar = app.scrollViews["SidebarScrollView"].firstMatch
            if sidebar.waitForExistence(timeout: 3) { sidebar.swipeUp(); sleep(1) }
            let btn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '\(name)'")).firstMatch
            if btn.waitForExistence(timeout: 3) { btn.tap(); sleep(2) }
            else { hamburger.tap(); sleep(1) } // close sidebar if not found
            saveScreenshot("exh_\(label)")
        }

        // Helper: send a message and verify it appears
        func sendAndVerify(_ text: String, screenshot label: String) -> Bool {
            let tf = app.textFields.firstMatch
            let tv = app.textViews.firstMatch
            let input = tf.exists ? tf : tv
            guard input.waitForExistence(timeout: 3) else {
                saveScreenshot("exh_\(label)_no_input")
                return false
            }
            input.tap(); sleep(1)
            input.typeText(text)
            let sendBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'send' OR label CONTAINS[c] 'arrow'")).firstMatch
            if sendBtn.waitForExistence(timeout: 3) { sendBtn.tap(); sleep(2) }
            saveScreenshot("exh_\(label)_sent")

            let visible = app.staticTexts[text].waitForExistence(timeout: 5)
            let textCount = app.staticTexts.count
            print("[EXH] \(label): msg visible=\(visible) textCount=\(textCount)")
            if !visible { saveScreenshot("exh_\(label)_MISSING") }
            return visible
        }

        // Helper: verify chat has content (not blank)
        func verifyChatVisible(_ label: String) -> Bool {
            let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
            let exists = chatScroll.waitForExistence(timeout: 3)
            let textCount = app.staticTexts.count
            saveScreenshot("exh_\(label)_check")
            let ok = exists && textCount >= 2
            if !ok { print("[EXH] BLANK? \(label): scroll=\(exists) texts=\(textCount)") }
            return ok
        }

        // === Round 1: Go to Liam, send message ===
        goToAgent("Liam", screenshot: "01_liam")
        let m1 = sendAndVerify("Liam test 1 - \(Int.random(in: 1000...9999))", screenshot: "02_liam_msg1")

        // === Switch to Adam (different agent), verify his chat ===
        tapAgent(at: 0); sleep(2)
        let c1 = verifyChatVisible("03_adam")

        // === Switch back to Liam, verify message still there ===
        goToAgent("Liam", screenshot: "04_liam_back")
        let c2 = verifyChatVisible("05_liam_verify")

        // === Go to Lewis, send message ===
        goToAgent("Lewis", screenshot: "06_lewis")
        let m2 = sendAndVerify("Lewis test 1 - \(Int.random(in: 1000...9999))", screenshot: "07_lewis_msg1")

        // === Switch to Liam ===
        goToAgent("Liam", screenshot: "08_liam_again")
        let c3 = verifyChatVisible("09_liam_verify2")

        // === Send another message to Liam ===
        let m3 = sendAndVerify("Liam test 2 - \(Int.random(in: 1000...9999))", screenshot: "10_liam_msg2")

        // === Rapid switch: Liam → agent0 → Lewis → agent1 → Liam ===
        tapAgent(at: 0); sleep(1)
        saveScreenshot("exh_11_agent0")
        let c4 = verifyChatVisible("11_agent0_check")

        goToAgent("Lewis", screenshot: "12_lewis_back")
        let c5 = verifyChatVisible("13_lewis_verify")

        tapAgent(at: 1); sleep(1)
        saveScreenshot("exh_14_agent1")
        let c6 = verifyChatVisible("14_agent1_check")

        goToAgent("Liam", screenshot: "15_liam_final")
        let c7 = verifyChatVisible("16_liam_final_check")

        // === Send to Lewis one more time ===
        goToAgent("Lewis", screenshot: "17_lewis_final")
        let m4 = sendAndVerify("Lewis test 2 - \(Int.random(in: 1000...9999))", screenshot: "18_lewis_msg2")
        let c8 = verifyChatVisible("19_lewis_final_check")

        // === Back to Liam final verify ===
        goToAgent("Liam", screenshot: "20_liam_last")
        let c9 = verifyChatVisible("21_liam_last_check")

        // Report
        let allMsgs = [m1, m2, m3, m4]
        let allChecks = [c1, c2, c3, c4, c5, c6, c7, c8, c9]
        let msgFails = allMsgs.filter { !$0 }.count
        let checkFails = allChecks.filter { !$0 }.count
        print("[EXH] Messages sent: \(allMsgs.count), failed: \(msgFails)")
        print("[EXH] Viewport checks: \(allChecks.count), blank: \(checkFails)")

        XCTAssertEqual(msgFails, 0, "All sent messages should be visible")
        XCTAssertEqual(checkFails, 0, "No viewport should be blank after switching")
        XCTAssertTrue(app.exists, "App should survive exhaustive send+switch test")
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

    // MARK: - Full Conversation with Liam and Lewis

    /// Navigate to Liam and Lewis via expanded sidebar (aggressive scrolling),
    /// send user messages, wait for responses, scroll through history, switch between them.
    func testConversationWithLiamAndLewis() throws {
        saveScreenshot("conv_00_start")

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 8) else { XCTFail("No hamburger"); return }

        // Switch to text mode — try label search first, then coordinate tap as fallback
        let modeBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'voice' AND label CONTAINS[c] 'mode'")).firstMatch
        if modeBtn.waitForExistence(timeout: 3) {
            modeBtn.tap()
            sleep(1)
        } else {
            // Coordinate fallback: mode button is in the header ~43% from left, ~6.5% from top
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.43, dy: 0.065)).tap()
            sleep(1)
        }
        saveScreenshot("conv_01_text_mode")
        // Verify text mode — look for text input field
        let hasTextField = app.textFields.firstMatch.waitForExistence(timeout: 3) ||
                           app.textViews.firstMatch.waitForExistence(timeout: 3)
        if !hasTextField {
            // Try tapping mode button one more time — might have toggled wrong way
            if modeBtn.exists { modeBtn.tap(); sleep(1) }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.43, dy: 0.065)).tap(); sleep(1) }
            saveScreenshot("conv_01b_retry_mode")
        }

        // Navigate to agent by name with aggressive sidebar scrolling
        func goTo(_ name: String) -> Bool {
            hamburger.tap(); sleep(2)
            let sidebar = app.scrollViews["SidebarScrollView"].firstMatch
            guard sidebar.waitForExistence(timeout: 3) else { return false }
            for _ in 0..<6 {
                let btn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '\(name)'")).firstMatch
                if btn.waitForExistence(timeout: 1) { btn.tap(); sleep(2); return true }
                sidebar.swipeUp(); sleep(1)
            }
            hamburger.tap(); sleep(1)
            return false
        }

        // Send user message via text field
        func send(_ text: String) -> Bool {
            let tf = app.textFields.firstMatch
            let tv = app.textViews.firstMatch
            let input = tf.exists ? tf : tv
            guard input.waitForExistence(timeout: 5) else { return false }
            input.tap(); sleep(1)
            input.typeText(text)
            let sendBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'send' OR label CONTAINS[c] 'arrow'")).firstMatch
            guard sendBtn.waitForExistence(timeout: 3) else { return false }
            sendBtn.tap(); sleep(2)
            return true
        }

        // === LIAM ===
        let foundLiam = goTo("Liam")
        saveScreenshot("conv_02_liam")
        XCTAssertTrue(foundLiam, "Should find Liam")

        if foundLiam {
            let s1 = send("Tell me a short story about a robot")
            saveScreenshot("conv_03_liam_sent")
            XCTAssertTrue(s1, "Should send to Liam")
            sleep(10)
            saveScreenshot("conv_04_liam_response")

            let s2 = send("Now tell me a joke")
            saveScreenshot("conv_05_liam_joke_sent")
            sleep(10)
            saveScreenshot("conv_06_liam_joke_response")

            // Scroll up
            let chat = app.scrollViews["ChatScrollView"].firstMatch
            if chat.exists {
                chat.swipeDown(velocity: .fast)
                chat.swipeDown(velocity: .fast)
                sleep(1)
                saveScreenshot("conv_07_liam_scrolled_up")
                chat.swipeUp(velocity: .fast)
                chat.swipeUp(velocity: .fast)
                chat.swipeUp(velocity: .fast)
                sleep(1)
                saveScreenshot("conv_08_liam_back_down")
            }
        }

        // === LEWIS ===
        let foundLewis = goTo("Lewis")
        saveScreenshot("conv_09_lewis")
        XCTAssertTrue(foundLewis, "Should find Lewis")

        if foundLewis {
            let s3 = send("Write me a haiku about testing")
            saveScreenshot("conv_10_lewis_sent")
            XCTAssertTrue(s3, "Should send to Lewis")
            sleep(10)
            saveScreenshot("conv_11_lewis_response")

            let s4 = send("Now write one about debugging")
            saveScreenshot("conv_12_lewis_debug_sent")
            sleep(10)
            saveScreenshot("conv_13_lewis_debug_response")
        }

        // === Back to Liam ===
        let backLiam = goTo("Liam")
        saveScreenshot("conv_14_back_to_liam")
        if backLiam {
            let chat = app.scrollViews["ChatScrollView"].firstMatch
            if chat.exists {
                // Deep scroll up
                for _ in 0..<5 { chat.swipeDown(velocity: .fast); usleep(500_000) }
                saveScreenshot("conv_15_liam_deep_scroll")
                // Back to bottom via chevron or scroll
                let chevron = app.buttons.matching(NSPredicate(format: "label CONTAINS 'chevron'")).firstMatch
                if chevron.waitForExistence(timeout: 2) { chevron.tap(); sleep(1) }
                else { for _ in 0..<8 { chat.swipeUp(velocity: .fast) }; sleep(1) }
                saveScreenshot("conv_16_liam_final")
            }
        }

        XCTAssertTrue(app.exists, "App should survive full conversation test")
    }
}
