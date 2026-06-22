import Foundation

/// App-side wiring for `-uiTestMode` (see `UITestContract`). Centralizes the stubs the
/// XCUITest smoke gate needs so the rest of the app stays oblivious to test mode:
/// a signed-in session with no network, sample workspaces, and dictation pre-granted.
///
/// Test mode exists because the visionOS Simulator can't automate the system permission
/// dialog (no `springboard` to tap "Allow") or the OAuth web flow. Rather than fight the
/// platform, the granted/signed-in state is synthesized here.
enum UITestSupport {
    /// Whether the app launched under the UI-test harness.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(UITestLaunch.argument)
    }

    /// An `AuthController` that restores straight to `.signedIn` against an in-memory
    /// token — no Keychain, no OAuth handoff. The dummy token is bearer-sent on cloud/relay
    /// calls, which simply fail (401) under test; the smoke flow never depends on a network
    /// response, only on the UI surviving the navigation.
    @MainActor
    static func makeAuthController() -> AuthController {
        let token = AuthToken(value: "ui-test-session", expiresAt: .distantFuture)
        return AuthController(tokenStore: InMemoryTokenStore(token: token))
    }

    /// A `LockController` whose Optic ID check always reports `.unavailable`, so the gate
    /// degrades to unlocked (ADR-0008 "graceful fallback per platform"). The visionOS
    /// Simulator's `LocalAuthentication` policy is non-deterministic across runtimes — some
    /// report a device-owner mechanism and leave the gate stuck on a prompt the test can't
    /// answer — so the lock is bypassed under test, matching the documented CI behavior
    /// (research/ui-test-automation.md: the lock flow is hardware/manual-QA-only).
    @MainActor
    static func makeLockController(relay: RelayCredentialGate) -> LockController {
        LockController(authenticator: AlwaysUnavailableAuthenticator(), relay: relay)
    }

    private struct AlwaysUnavailableAuthenticator: LocalAuthenticating {
        func evaluate(reason: String) async -> LocalAuthOutcome { .unavailable }
    }
}
