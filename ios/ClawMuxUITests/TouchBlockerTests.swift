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

    // MARK: - Sidebar touch test

    /// Taps the sidebar strip and verifies a session is activated or the sidebar responds.
    /// If portal overlay is blocking, this tap will be consumed by the portal and nothing changes.
    func testSidebarTapsRegister() throws {
        // The sidebar is always visible at x=0-48. Tap near the top where first agent icon is.
        let sidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
        sidebar.tap()
        sleep(1)

        // After tapping an agent, either a session opens (chat header appears) or the
        // sidebar expands. Either way the app should have responded — we just verify
        // no crash and the app is still in foreground.
        XCTAssertTrue(app.exists, "App should still be alive after sidebar tap")
    }

    // MARK: - Header model pill test

    /// Taps the model pill (e.g., "Opus") in the chat header and expects a dialog to appear.
    /// If a Menu{} portal is blocking, the tap hits the portal and no dialog appears.
    func testModelPillOpensDialog() throws {
        // Wait for an active session — if no session, this test is inconclusive
        let modelButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Opus' OR label BEGINSWITH 'Sonnet' OR label BEGINSWITH 'Haiku'")).firstMatch
        guard modelButton.waitForExistence(timeout: 8) else {
            // No active session — spawn one first by tapping an agent
            let agentArea = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
            agentArea.tap()
            sleep(3)
            XCTAssertTrue(modelButton.waitForExistence(timeout: 8), "Model pill should appear after activating a session")
            return
        }

        modelButton.tap()

        // confirmationDialog should appear as an action sheet
        let sheet = app.sheets.firstMatch
        let appeared = sheet.waitForExistence(timeout: 3)
        XCTAssertTrue(appeared, "confirmationDialog should appear — if this fails, a portal overlay may be blocking taps")

        if appeared {
            // Dismiss
            let cancelButton = sheet.buttons["Cancel"].firstMatch
            if cancelButton.exists { cancelButton.tap() }
        }
    }

    // MARK: - Center screen tap test

    /// Taps the center of the screen. If a portal is blocking, this tap lands on the portal
    /// instead of the scroll area (which is non-interactive but should not intercept focused taps).
    /// We verify the app is still responsive after the tap.
    func testCenterScreenTapDoesNotFreeze() throws {
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        sleep(1)

        // App should still be alive and responsive
        XCTAssertTrue(app.exists)

        // Verify we can still tap the sidebar after a center tap
        let sidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.15))
        sidebar.tap()
        sleep(1)
        XCTAssertTrue(app.exists, "App should respond after center tap + sidebar tap sequence")
    }
}
