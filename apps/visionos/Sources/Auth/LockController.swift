import Foundation
import Observation

/// The relay-credential side of the Optic ID gate (ADR-0008). The lock both drops the
/// cached relay JWT and *blocks re-minting* until the owner re-authenticates, so a poll
/// loop that ticks behind the lock screen can't quietly re-acquire the RCE-grade token
/// before Optic ID lands. `AuthController` owns the cache and satisfies this seam.
@MainActor
protocol RelayCredentialGate: AnyObject {
    /// Drop the cached relay JWT now (proactive, ahead of the ~1h revocation lag).
    func dropRelayToken()
    /// Gate minting: while locked, the provider refuses to mint a new JWT. `generation`
    /// orders this against other seal/release calls so the gate ends up matching the
    /// latest `LockState` regardless of which hop reaches the provider last.
    func setRelayLocked(_ locked: Bool, generation: Int)
}

/// Where the wearer stands at the Optic ID gate. Distinct from `AuthStatus`: a user can
/// be signed in (session token in the Keychain) yet locked (the headset was set down /
/// backgrounded and not re-verified).
enum LockState: Equatable {
    /// The owner is verified; content is visible.
    case unlocked
    /// Needs Optic ID — idle, awaiting the prompt (launch, foreground, or a prior failure).
    case locked
    /// The Optic ID prompt is in flight.
    case authenticating
    /// The last attempt failed with a presentable message; the owner can retry.
    case failed(String)
}

/// Drives the Optic ID gate over the app's signed-in content (ADR-0008, "put it on, see
/// your workspaces"). Owns the lock state every window observes and coordinates the relay
/// credential: locking drops + blocks the JWT, a passing Optic ID re-enables minting.
///
/// Starts `.locked` so launch and every foreground require the owner; a fresh OAuth
/// sign-in (`unlock()`) skips the redundant prompt since identity was just proven in the
/// browser.
@MainActor
@Observable
final class LockController {
    private(set) var state: LockState = .locked

    private let authenticator: LocalAuthenticating
    private let relay: RelayCredentialGate?
    private let reason: String
    /// Monotonic token bumped on every seal/release so the relay actor can discard a hop
    /// that lands out of order (lock → authenticate → unlock fire as independent tasks).
    private var relayGeneration = 0

    init(
        authenticator: LocalAuthenticating = OpticIDAuthenticator(),
        relay: RelayCredentialGate? = nil,
        reason: String = "Unlock Superset to see your workspaces."
    ) {
        self.authenticator = authenticator
        self.relay = relay
        self.reason = reason
    }

    var isLocked: Bool { state != .unlocked }

    /// Enter the locked state and seal the relay credential: sealing also drops the cached
    /// JWT and blocks re-minting until a passing Optic ID. Idempotent — safe to call from
    /// every window's background transition and from the launch gate.
    func lock() {
        sealRelay(true)
        if state == .authenticating { return }
        state = .locked
    }

    /// Run the Optic ID check. No-op unless idle-locked (prevents a second system prompt
    /// when several windows foreground at once). A pass — or a platform with no owner
    /// mechanism to evaluate — unlocks and re-enables relay minting.
    func authenticate() async {
        guard state == .locked || isFailed else { return }
        state = .authenticating
        let outcome = await authenticator.evaluate(reason: reason)
        switch outcome {
        case .success, .unavailable:
            unlock()
        case let .failure(message):
            state = .failed(message)
        }
    }

    /// Force unlock without an Optic ID prompt — used right after a fresh OAuth sign-in,
    /// where the browser handoff already proved the owner.
    func unlock() {
        sealRelay(false)
        state = .unlocked
    }

    /// Issue a seal/release to the relay gate under a fresh generation. The state mutation
    /// in `lock()`/`unlock()` stays synchronous (its current ordering is load-bearing for
    /// the multi-window launch gate); the generation lets the actor settle on whichever
    /// intent was minted last even though these hops cross the actor boundary unordered.
    private func sealRelay(_ sealed: Bool) {
        relayGeneration += 1
        relay?.setRelayLocked(sealed, generation: relayGeneration)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
