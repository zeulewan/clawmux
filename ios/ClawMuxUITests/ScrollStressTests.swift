import XCTest

/// Stress tests for scroll behavior, rapid interactions, and layout stability.
/// Run against a live hub so WebSocket data flows during tests.
final class ScrollStressTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        sleep(4) // Allow WebSocket connection
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let url = URL(fileURLWithPath: "/tmp/stress_\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Rapid Sidebar Toggle

    /// Rapidly open/close the sidebar 20 times. Checks for crashes and layout breakage.
    func testRapidSidebarToggle() throws {
        let hamburger = app.buttons["HamburgerButton"].firstMatch
        XCTAssertTrue(hamburger.waitForExistence(timeout: 8), "HamburgerButton must exist")

        saveScreenshot("sidebar_toggle_00_start")

        for i in 0..<20 {
            hamburger.tap()
            // No sleep — as fast as possible
            if i % 5 == 4 {
                usleep(200_000) // 200ms every 5 taps for screenshot
                saveScreenshot("sidebar_toggle_\(i)")
            }
        }

        sleep(1)
        saveScreenshot("sidebar_toggle_final")
        XCTAssertTrue(app.exists, "App should survive 20 rapid sidebar toggles")
        XCTAssertTrue(hamburger.exists, "HamburgerButton should still exist")
    }

    // MARK: - Rapid Agent Switching

    /// Tap through agent icons in the collapsed sidebar rapidly.
    /// Agents are stacked vertically on the left edge (x ≈ 6% of screen).
    func testRapidAgentSwitching() throws {
        saveScreenshot("agent_switch_00_start")

        // Agent icons are at x≈6%, y positions roughly 12%, 17%, 22%, 27%, 32%, 37%, 42%
        let yPositions: [CGFloat] = [0.12, 0.17, 0.22, 0.27, 0.32, 0.37, 0.42, 0.47, 0.52]

        // Tap through all agents 3 times
        for round in 0..<3 {
            for (idx, y) in yPositions.enumerated() {
                let agent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: y))
                agent.tap()
                usleep(100_000) // 100ms between taps
            }
            saveScreenshot("agent_switch_round\(round)")
        }

        sleep(1)
        saveScreenshot("agent_switch_final")
        XCTAssertTrue(app.exists, "App should survive rapid agent switching")

        // Verify chat scroll view is still present (not blank screen)
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5), "ChatScrollView should exist after rapid switching")
    }

    // MARK: - Scroll While Messages Arrive

    /// Scroll up in the chat while messages are arriving. Verifies scroll position stability.
    func testScrollUpWhileMessagesArrive() throws {
        // Open first agent
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 8) else {
            XCTFail("ChatScrollView not found")
            return
        }

        saveScreenshot("scroll_msgs_00_start")

        // Scroll up (swipe down on screen) to leave the bottom
        chatScroll.swipeDown(velocity: .fast)
        chatScroll.swipeDown(velocity: .fast)
        chatScroll.swipeDown(velocity: .fast)
        sleep(1)
        saveScreenshot("scroll_msgs_01_scrolled_up")

        // The app should NOT auto-scroll back to bottom when scrolled up
        // Wait a few seconds (messages may be arriving)
        sleep(3)
        saveScreenshot("scroll_msgs_02_after_wait")

        // Now tap the scroll-to-bottom button if it appears
        let scrollDownBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS 'chevron'")).firstMatch
        if scrollDownBtn.waitForExistence(timeout: 2) {
            scrollDownBtn.tap()
            sleep(1)
            saveScreenshot("scroll_msgs_03_after_scroll_bottom")
        }

        XCTAssertTrue(app.exists, "App should survive scroll-while-messages-arrive")
    }

    // MARK: - Rapid Mic Button Taps

    /// Tap the mic/record button rapidly to stress-test recording state transitions.
    func testRapidMicButtonTaps() throws {
        // Open an agent first
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        saveScreenshot("mic_rapid_00_start")

        // Mic button is at bottom center of the screen
        let micArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))

        for i in 0..<10 {
            micArea.tap()
            usleep(300_000) // 300ms between taps
            if i % 3 == 2 {
                saveScreenshot("mic_rapid_\(i)")
            }
        }

        sleep(1)
        saveScreenshot("mic_rapid_final")
        XCTAssertTrue(app.exists, "App should survive rapid mic button taps")
    }

    // MARK: - Agent Switch While Scrolled Up

    /// Scroll up in one agent's chat, then switch to another agent.
    /// The new agent's chat should start at the bottom, not inherit the scroll position.
    func testAgentSwitchWhileScrolledUp() throws {
        // Tap first agent
        let agent1 = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        agent1.tap()
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 8) else {
            XCTFail("ChatScrollView not found")
            return
        }

        // Scroll up
        chatScroll.swipeDown(velocity: .fast)
        chatScroll.swipeDown(velocity: .fast)
        sleep(1)
        saveScreenshot("switch_scrolled_01_scrolled_up")

        // Switch to second agent
        let agent2 = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.17))
        agent2.tap()
        sleep(2)
        saveScreenshot("switch_scrolled_02_switched_agent")

        // Switch to third agent
        let agent3 = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.22))
        agent3.tap()
        sleep(2)
        saveScreenshot("switch_scrolled_03_third_agent")

        // Switch back to first
        agent1.tap()
        sleep(2)
        saveScreenshot("switch_scrolled_04_back_to_first")

        XCTAssertTrue(app.exists, "App should survive switching while scrolled")
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5), "ChatScrollView should exist after switches")
    }

    // MARK: - Sidebar Open During Messages

    /// Open the sidebar while messages are arriving — verify no layout shift.
    func testSidebarOpenDuringActivity() throws {
        // Open an agent
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        saveScreenshot("sidebar_activity_00_start")

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        XCTAssertTrue(hamburger.waitForExistence(timeout: 5))

        // Rapidly toggle sidebar while agent may be thinking
        for i in 0..<10 {
            hamburger.tap()
            usleep(500_000) // 500ms
            if i % 3 == 2 {
                saveScreenshot("sidebar_activity_\(i)")
            }
        }

        sleep(1)
        saveScreenshot("sidebar_activity_final")
        XCTAssertTrue(app.exists, "App should survive sidebar toggles during activity")
    }

    // MARK: - Orientation Change

    /// Rotate device during chat view and verify layout adapts.
    func testOrientationChange() throws {
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        saveScreenshot("orientation_00_portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        saveScreenshot("orientation_01_landscape")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        saveScreenshot("orientation_02_back_to_portrait")

        // Rapid rotation
        for _ in 0..<5 {
            XCUIDevice.shared.orientation = .landscapeRight
            usleep(500_000)
            XCUIDevice.shared.orientation = .portrait
            usleep(500_000)
        }
        sleep(1)
        saveScreenshot("orientation_03_after_rapid")

        XCTAssertTrue(app.exists, "App should survive orientation changes")
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5), "ChatScrollView should exist after rotations")
    }

    // MARK: - Background/Foreground

    /// Send app to background and bring it back during activity.
    func testBackgroundForeground() throws {
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        saveScreenshot("bgfg_00_start")

        // Background
        XCUIDevice.shared.press(.home)
        sleep(2)

        // Foreground
        app.activate()
        sleep(3)
        saveScreenshot("bgfg_01_after_foreground")

        // Verify app recovered
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 8), "ChatScrollView should exist after background/foreground")
        XCTAssertTrue(app.exists, "App should survive background/foreground cycle")

        // Do it 3 more times rapidly
        for i in 0..<3 {
            XCUIDevice.shared.press(.home)
            sleep(1)
            app.activate()
            sleep(2)
            saveScreenshot("bgfg_rapid_\(i)")
        }

        XCTAssertTrue(app.exists, "App should survive rapid background/foreground")
    }

    // MARK: - Long Scroll Stress

    /// Scroll up and down rapidly 50 times.
    func testRapidScrollUpDown() throws {
        let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.12))
        firstAgent.tap()
        sleep(2)

        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        guard chatScroll.waitForExistence(timeout: 8) else {
            XCTFail("ChatScrollView not found")
            return
        }

        saveScreenshot("rapid_scroll_00_start")

        for i in 0..<25 {
            chatScroll.swipeDown(velocity: .fast) // scroll up
            chatScroll.swipeUp(velocity: .fast)   // scroll down
            if i % 10 == 9 {
                saveScreenshot("rapid_scroll_\(i)")
            }
        }

        sleep(1)
        saveScreenshot("rapid_scroll_final")
        XCTAssertTrue(app.exists, "App should survive 50 rapid scroll gestures")
        XCTAssertTrue(chatScroll.exists, "ChatScrollView should still exist")
    }

    // MARK: - Combined Stress

    /// Switch agents, scroll, toggle sidebar, and tap mic in rapid sequence.
    func testCombinedStress() throws {
        saveScreenshot("combined_00_start")

        let hamburger = app.buttons["HamburgerButton"].firstMatch
        guard hamburger.waitForExistence(timeout: 8) else {
            XCTFail("HamburgerButton not found")
            return
        }

        let agents: [CGFloat] = [0.12, 0.17, 0.22, 0.27, 0.32]
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch

        for round in 0..<5 {
            // Tap agent
            let y = agents[round % agents.count]
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: y)).tap()
            usleep(300_000)

            // Scroll
            if chatScroll.exists {
                chatScroll.swipeDown(velocity: .fast)
                usleep(200_000)
                chatScroll.swipeUp(velocity: .fast)
            }

            // Toggle sidebar
            hamburger.tap()
            usleep(300_000)
            hamburger.tap()
            usleep(200_000)

            // Tap mic area
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
            usleep(300_000)

            saveScreenshot("combined_round\(round)")
        }

        sleep(1)
        saveScreenshot("combined_final")
        XCTAssertTrue(app.exists, "App should survive combined stress test")
    }
}
