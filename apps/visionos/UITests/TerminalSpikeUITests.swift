import XCTest

/// Phase-1 spike gate for the `TerminalSurface` integration. Drives the real entry point
/// — workspace list → Settings → Debug → "Open Terminal Spike" — then proves the surface
/// renders, accepts typing without crashing, and that a second terminal coexists.
///
/// Runs under `-uiTestMode` (stubbed signed-in session, sample workspaces, no network),
/// the same harness as the smoke gate. The libghostty surface is a Metal `CAMetalLayer`,
/// not in the accessibility tree, so its content is evidenced by screenshots and by the
/// app staying `runningForeground` through the type + two-up path rather than by querying
/// the rendered glyphs.
@MainActor
final class TerminalSpikeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTerminalRendersEchoesAndCoexists() throws {
        // libghostty's HOST_MANAGED backend fires receive_buffer / receive_resize on its
        // `termio` IO thread. The TerminalSurface package now routes those callbacks to a
        // lock-guarded Sendable TerminalOutputSink (no MainActor.assumeIsolated, no main
        // hop), so bring-up no longer traps off-main.
        let app = XCUIApplication()
        app.launchArguments.append(UITestLaunch.argument)
        app.launch()

        let authRoot = app.otherElements[AccessibilityID.authGateRoot]
        XCTAssertTrue(authRoot.waitForExistence(timeout: 30), "Signed-in root never appeared")

        // Rail → Settings window.
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Settings rail item missing")
        settings.tap()

        // Settings is a category split view whose sidebar rows surface as static-text
        // cells; select the Debug category to reveal its pane.
        let debugCategory = app.staticTexts["Debug"]
        XCTAssertTrue(debugCategory.waitForExistence(timeout: 20), "Debug settings category missing")
        debugCategory.tap()

        // Debug pane → Debug window.
        let openDebug = app.buttons["Open Debug Window"]
        XCTAssertTrue(openDebug.waitForExistence(timeout: 20), "Open Debug Window button missing")
        openDebug.tap()

        // Debug → Terminal spike window.
        let openTerminal = app.buttons["open-terminal-spike"]
        XCTAssertTrue(openTerminal.waitForExistence(timeout: 20), "Open Terminal Spike button missing")
        let windowsBefore = app.windows.count
        openTerminal.tap()

        // The two-up toggle lives only in the terminal window — its presence proves the
        // window opened and the SwiftUI host of the surface mounted. A button-styled
        // SwiftUI Toggle surfaces as a `Switch` in the accessibility tree, not a button.
        let twoUp = app.switches["terminal-two-up-toggle"]
        XCTAssertTrue(twoUp.waitForExistence(timeout: 20), "Terminal window did not open")
        XCTAssertGreaterThan(app.windows.count, windowsBefore, "Expected a new window for the terminal")
        attachScreenshot(app, name: "01-terminal-rendered")

        // The surface becomes first responder on appear; type into it. Loopback echoes
        // each keystroke back to the screen (CR→CRLF cooked). The gate is that the app
        // survives routing hardware keys into libghostty's input path.
        app.typeText("echo works\r")
        XCTAssertEqual(app.state, .runningForeground, "App died while typing into the terminal")
        attachScreenshot(app, name: "02-after-typing")

        // Flip on the second terminal: two independent controllers/surfaces side by side.
        twoUp.tap()
        XCTAssertEqual(app.state, .runningForeground, "App died after enabling the second terminal")
        attachScreenshot(app, name: "03-two-terminals")

        // Type again with both live — proves the focused surface still takes input and the
        // two coexist without tearing each other down.
        app.typeText("two up\r")
        XCTAssertEqual(app.state, .runningForeground, "App died typing with two terminals live")
        attachScreenshot(app, name: "04-two-terminals-typed")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
