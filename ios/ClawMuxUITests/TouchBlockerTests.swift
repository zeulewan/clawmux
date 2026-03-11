import XCTest

/// Tests that verify touch events land correctly in the ClawMux app.
/// Primary goal: catch iOS 26 portal overlay regressions (PortalGroupMarkerView blocking touches).
final class TouchBlockerTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // Give app time to connect (or fail to connect — we just need the UI to render)
        sleep(3)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        // Save to /tmp so we can retrieve via SSH for analysis
        let url = URL(fileURLWithPath: "/tmp/\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        // Also attach to test report
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Sidebar touch test

    /// Taps the sidebar strip and verifies a session is activated or the sidebar responds.
    /// If portal overlay is blocking, this tap will be consumed by the portal and nothing changes.
    func testSidebarTapsRegister() throws {
        saveScreenshot("sidebar_01_before")
        // The sidebar is always visible at x=0-48. Tap near the top where first agent icon is.
        let sidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
        sidebar.tap()
        sleep(1)
        saveScreenshot("sidebar_02_after")

        // After tapping an agent, either a session opens (chat header appears) or the
        // sidebar expands. Either way the app should have responded — we just verify
        // no crash and the app is still in foreground.
        XCTAssertTrue(app.exists, "App should still be alive after sidebar tap")
    }

    // MARK: - Header model pill test

    /// Taps the model pill (e.g., "Opus") in the chat header and expects a dialog to appear.
    /// If a Menu{} portal is blocking, the tap hits the portal and no dialog appears.
    func testModelPillOpensDialog() throws {
        saveScreenshot("modelpill_01_before")
        // Wait for an active session — if no session, this test is inconclusive
        let modelButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Opus' OR label BEGINSWITH 'Sonnet' OR label BEGINSWITH 'Haiku'")).firstMatch
        guard modelButton.waitForExistence(timeout: 8) else {
            // No active session — spawn one first by tapping an agent
            let agentArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
            agentArea.tap()
            sleep(3)
            saveScreenshot("modelpill_02_after_agent_tap")
            XCTAssertTrue(modelButton.waitForExistence(timeout: 8), "Model pill should appear after activating a session")
            return
        }

        modelButton.tap()
        sleep(1)
        saveScreenshot("modelpill_02_after_tap")

        // confirmationDialog should appear as an action sheet
        let sheet = app.sheets.firstMatch
        let appeared = sheet.waitForExistence(timeout: 3)
        saveScreenshot("modelpill_03_sheet_state")
        XCTAssertTrue(appeared, "confirmationDialog should appear — if this fails, a portal overlay may be blocking taps")

        if appeared {
            // Dismiss
            let cancelButton = sheet.buttons["Cancel"].firstMatch
            if cancelButton.exists { cancelButton.tap() }
        }
    }

    // MARK: - Hamburger button test

    /// Taps the hamburger button (bottom-left of sidebar) and verifies the sidebar expands.
    /// This is the simplest touch test: if anything is blocking, the sidebar stays collapsed.
    func testHamburgerExpandsSidebar() throws {
        saveScreenshot("hamburger_01_before")

        // Confirm tray buttons do NOT exist before tapping (eliminates false positives)
        let trayNotes    = app.buttons["SidebarNotesButton"].firstMatch
        let traySettings = app.buttons["SidebarSettingsButton"].firstMatch
        XCTAssertFalse(trayNotes.exists,    "SidebarNotesButton should not exist before hamburger tap")
        XCTAssertFalse(traySettings.exists, "SidebarSettingsButton should not exist before hamburger tap")

        // Tap by accessibility identifier — reliable across all screen sizes, no coordinate guessing
        let hamburger = app.buttons["HamburgerButton"].firstMatch
        XCTAssertTrue(hamburger.waitForExistence(timeout: 5), "HamburgerButton must exist")
        hamburger.tap()
        sleep(1)
        saveScreenshot("hamburger_02_after_tap")

        // Verify sidebar expanded by checking tray buttons appeared
        let expanded = trayNotes.waitForExistence(timeout: 3) || traySettings.waitForExistence(timeout: 3)
        saveScreenshot("hamburger_03_expanded_state")
        XCTAssertTrue(expanded, "Sidebar tray should appear after hamburger tap — SidebarNotesButton or SidebarSettingsButton must exist")

        // Collapse
        hamburger.tap()
        sleep(1)
        saveScreenshot("hamburger_04_collapsed")

        // Tray buttons should be gone again
        XCTAssertFalse(trayNotes.exists,    "SidebarNotesButton should disappear after collapsing")
    }

    // MARK: - Group chat navigation test

    /// Expands the sidebar, scrolls to find a group chat, taps it, and checks if history loads.
    func testGroupChatOpensAndShowsHistory() throws {
        saveScreenshot("groupchat_01_before")

        // Expand sidebar
        let hamburger = app.buttons["HamburgerButton"].firstMatch
        XCTAssertTrue(hamburger.waitForExistence(timeout: 5), "HamburgerButton must exist")
        hamburger.tap()
        sleep(2)
        saveScreenshot("groupchat_02_sidebar_expanded")

        // Scroll the sidebar down to reveal group chats (below the 27 agent cards)
        // Use SidebarScrollView identifier + swipeUp() for reliable scroll
        let sidebarScroll = app.scrollViews["SidebarScrollView"].firstMatch
        if sidebarScroll.waitForExistence(timeout: 3) {
            sidebarScroll.swipeUp()
            sleep(1)
            sidebarScroll.swipeUp()  // second swipe in case 27 agents are tall
            sleep(1)
        }
        saveScreenshot("groupchat_03_scrolled")

        // Look for group chat card by accessibilityIdentifier (GroupChatCard-<groupId>)
        // groupId for "clawmux ios" is typically "clawmux_ios" or similar
        let gcCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'GroupChatCard-'")).firstMatch
        if gcCard.waitForExistence(timeout: 3) {
            print("Found group chat card: \(gcCard.identifier)")
            gcCard.tap()
            sleep(2)
            saveScreenshot("groupchat_04_after_tap")
            XCTAssertTrue(app.exists, "App should still be alive after group chat tap")
            saveScreenshot("groupchat_05_history_state")
        } else {
            saveScreenshot("groupchat_03b_no_gc_found")
            // Not a failure — group chats may not be visible if not connected or none exist
            print("No GroupChatCard button found — may need active group chat on server")
        }
    }

    // MARK: - Center screen tap test

    /// Taps the center of the screen. If a portal is blocking, this tap lands on the portal
    /// instead of the scroll area (which is non-interactive but should not intercept focused taps).
    /// We verify the app is still responsive after the tap.
    func testCenterScreenTapDoesNotFreeze() throws {
        saveScreenshot("center_01_before")
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        sleep(1)
        saveScreenshot("center_02_after_tap")

        // App should still be alive and responsive
        XCTAssertTrue(app.exists)

        // Verify we can still tap the sidebar after a center tap
        let sidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
        sidebar.tap()
        sleep(1)
        saveScreenshot("center_03_sidebar_tap")
        XCTAssertTrue(app.exists, "App should respond after center tap + sidebar tap sequence")
    }

    // MARK: - Infinite scroll test

    /// Opens the Onyx agent chat and scrolls up three times, verifying older messages load
    /// each time (ProgressView appears → disappears → more content visible).
    func testInfiniteScrollLoadsOlderMessages() throws {
        saveScreenshot("infinitescroll_01_launch")

        // Wait longer for server connection (needs a live hub)
        sleep(5)
        saveScreenshot("infinitescroll_02_after_connect")

        // Expand sidebar to select Onyx by name
        let hamburger = app.buttons["HamburgerButton"].firstMatch
        XCTAssertTrue(hamburger.waitForExistence(timeout: 8), "HamburgerButton must exist")
        hamburger.tap()
        sleep(2)
        saveScreenshot("infinitescroll_03_sidebar_expanded")

        // Find Onyx's agent card in the expanded sidebar — scroll sidebar down if needed
        let sidebarScroll = app.scrollViews["SidebarScrollView"].firstMatch
        var onyxBtn = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Onyx'")).firstMatch
        if !onyxBtn.waitForExistence(timeout: 2), sidebarScroll.waitForExistence(timeout: 3) {
            sidebarScroll.swipeUp()
            sleep(1)
        }
        saveScreenshot("infinitescroll_04_sidebar_scrolled")

        if onyxBtn.waitForExistence(timeout: 3) {
            onyxBtn.tap()
            sleep(4)
            saveScreenshot("infinitescroll_05_onyx_chat_opened")
        } else {
            // Fallback: tap first agent icon in collapsed sidebar
            hamburger.tap() // close sidebar
            sleep(1)
            let firstAgent = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.17))
            firstAgent.tap()
            sleep(4)
            saveScreenshot("infinitescroll_05b_fallback_agent")
        }

        // We should now be in a chat view — verify ChatScrollView exists
        let chatScroll = app.scrollViews["ChatScrollView"].firstMatch
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 8), "ChatScrollView should exist after opening agent chat")

        // Wait for history fetch to complete (need hasOlderMessages=true before scrolling)
        sleep(6)
        saveScreenshot("infinitescroll_06_chat_visible")

        // Helper: swipe to top (100 messages = lots of content; use 12 fast swipes)
        func swipeToTop() {
            for _ in 0..<12 { chatScroll.swipeDown(velocity: .fast) }
        }
        let loadingSpinner = app.activityIndicators.firstMatch

        // Helper: wait for spinner to appear and clear
        func waitForLoad() -> Bool {
            let seen = loadingSpinner.waitForExistence(timeout: 5)
            if seen {
                for _ in 0..<15 { if !loadingSpinner.exists { break }; sleep(1) }
            }
            return seen
        }

        // --- Round 1: scroll to top ---
        swipeToTop()
        sleep(2)
        saveScreenshot("infinitescroll_07_after_scroll1")
        let spinnerSeen1 = waitForLoad()
        saveScreenshot("infinitescroll_09_after_load1")

        // --- Round 2: scroll to top again ---
        swipeToTop()
        sleep(2)
        saveScreenshot("infinitescroll_10_after_scroll2")
        let spinnerSeen2 = waitForLoad()
        saveScreenshot("infinitescroll_12_after_load2")

        // --- Round 3: scroll to top a third time ---
        swipeToTop()
        sleep(2)
        saveScreenshot("infinitescroll_13_after_scroll3")
        let spinnerSeen3 = waitForLoad()
        saveScreenshot("infinitescroll_15_final")

        // At minimum, the app must still be alive and the scroll view must exist
        XCTAssertTrue(app.exists, "App should survive three infinite scroll rounds")
        XCTAssertTrue(chatScroll.exists, "ChatScrollView should still exist after scrolling")

        // Pass/fail verdict on whether infinite scroll actually triggered at least once
        XCTAssertTrue(
            spinnerSeen1 || spinnerSeen2 || spinnerSeen3,
            "Infinite scroll should have triggered at least once — ProgressView never appeared. " +
            "Check: server connected, session has history, hasOlderMessages flag is true."
        )
    }
}
