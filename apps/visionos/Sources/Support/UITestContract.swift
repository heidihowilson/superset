import Foundation

/// The contract the app and its XCUITest target share: the launch argument that switches
/// the app into a deterministic, network-free test mode, and the accessibility identifiers
/// the smoke test drives the UI through. This one file is compiled into *both* targets
/// (see `project.yml`) so the two sides can never drift on a string literal.
enum UITestLaunch {
    /// Passed in `XCUIApplication.launchArguments`. When present, the app stubs a
    /// signed-in session, seeds sample workspaces, and pre-grants dictation — the
    /// visionOS permission dialog and OAuth web flow can't be automated (no springboard),
    /// so the granted state is synthesized in-app rather than tapped.
    static let argument = "-uiTestMode"
}

/// Accessibility identifiers for the elements the smoke test queries. Driving the app by
/// stable identifiers (not localized labels or layout position) keeps the test resilient
/// to copy and chrome changes.
enum AccessibilityID {
    /// The signed-in root surface (the command-center window's content).
    static let authGateRoot = "auth-gate-root"
    /// The workspace browser list.
    static let workspaceList = "workspace-list"
    /// Prefix for a tappable workspace row; the full id appends the workspace's id.
    static let workspaceRowPrefix = "workspace-row-"
    /// The Workspace window's title (the workspace name) — the proof a second window opened.
    /// Identifiers go on leaf elements, never the window's container: a container-level
    /// identifier propagates to and clobbers every descendant's identifier in SwiftUI.
    static let workspaceWindowTitle = "workspace-window-title"
    /// The composer's prompt text field.
    static let composerInput = "composer-input"
    /// The composer's dictation mic toggle.
    static let composerMicToggle = "composer-mic-toggle"

    /// The full identifier for a workspace row, given its workspace id.
    static func workspaceRow(_ id: String) -> String { workspaceRowPrefix + id }
}
