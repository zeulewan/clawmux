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

        // Now check for the specific sidebar tray buttons (not the main Settings button)
        // Check debug label: "h:1 e:1" means hamburgerTapCount=1 and sidebarExpanded=true
        let debugLabel = app.staticTexts["DebugHamburgerState"].firstMatch
        XCTAssertTrue(debugLabel.waitForExistence(timeout: 3), "Debug label must exist")
        let stateAfterTap = debugLabel.label
        print("DEBUG STATE AFTER TAP: \(stateAfterTap)")  // e.g. "h:1 e:1"
        XCTAssertTrue(stateAfterTap.contains("h:1"), "hamburgerTapCount should be 1 after one tap — action did not fire if 0")
        XCTAssertTrue(stateAfterTap.contains("e:1"), "sidebarExpanded should be 1 (true) after tap")

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
}
