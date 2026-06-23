import XCTest

/// The loop's external smoke gate (research/ui-test-automation.md). Drives the app through
/// the accessibility tree on the visionOS Simulator — no gaze/pinch to simulate, the system
/// resolves `.tap()` directly. It upgrades CI from "builds + launches" to "builds +
/// navigates + opens a window + survives the dictation path", closing the gap that let the
/// dictation-auth crash reach hardware.
///
/// Runs under `-uiTestMode`: a stubbed signed-in session, sample workspaces (no network),
/// and pre-granted dictation. What this *can't* cover is hardware/manual-QA-only and
/// deliberately so: Optic ID (`LocalAuthentication` is `.unavailable` on the Simulator, so
/// the lock degrades to unlocked), eye-gaze targeting, live mic + on-device speech, and the
/// real TCC permission dialog (the Simulator has no `springboard` to tap "Allow", and
/// `simctl privacy` can grant microphone but not speech-recognition — so the granted state
/// is synthesized in-app rather than driven here).
@MainActor
final class SupersetUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSmokeOpenWorkspaceAndDictation() {
        let app = XCUIApplication()
        app.launchArguments.append(UITestLaunch.argument)
        app.launch()

        // Launch → signed-in surface. A brief Optic ID cover may flash before the Simulator's
        // unavailable-policy unlock lands, so wait rather than assert immediately.
        let authRoot = app.otherElements[AccessibilityID.authGateRoot]
        XCTAssertTrue(authRoot.waitForExistence(timeout: 30), "Signed-in root never appeared")

        // Assert the workspace list rendered by waiting for a tappable workspace row
        // (a visionOS `List` surfaces as a collection view, so query the row button — the
        // real navigation target — rather than the list container).
        let rowPredicate = NSPredicate(
            format: "identifier BEGINSWITH %@", AccessibilityID.workspaceRowPrefix
        )
        let firstRow = app.buttons.matching(rowPredicate).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20), "Workspace list never appeared")
        attachScreenshot(app, name: "01-workspace-list")

        // Tap a workspace row → its own window opens (PRD §7.1, window-per-workspace).
        let windowsBefore = app.windows.count
        firstRow.tap()

        // Assert a *second* window opened (existence + contents, never geometry — the system
        // owns placement). The window's title — a `Text`, which surfaces reliably as a
        // static text — appearing in the new scene is the proof.
        let windowTitle = app.staticTexts[AccessibilityID.workspaceWindowTitle]
        XCTAssertTrue(windowTitle.waitForExistence(timeout: 20), "Workspace window did not open")
        XCTAssertGreaterThan(
            app.windows.count, windowsBefore,
            "Expected a second window after opening a workspace"
        )
        attachScreenshot(app, name: "02-workspace-window")

        // Focus the composer, then toggle the dictation mic. A surviving query *after* the
        // mic tap is the crash gate — the dictation-auth trap fired on this exact path.
        let composer = app.textFields[AccessibilityID.composerInput]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Composer input missing")
        composer.tap()

        let mic = app.buttons[AccessibilityID.composerMicToggle]
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "Dictation mic toggle missing")
        mic.tap()

        // The gate: the app is still alive and responsive after exercising the dictation path.
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "App did not survive the dictation path")
        XCTAssertEqual(app.state, .runningForeground, "App is no longer running after mic tap")
        attachScreenshot(app, name: "03-after-dictation")
    }

    /// Attach a screenshot to the result bundle for triage (free; no pixel-diffing yet).
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
