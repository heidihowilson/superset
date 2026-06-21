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
    /// Gate minting: while locked, the provider refuses to mint a new JWT. Awaited as part
    /// of the lock transition so the seal/release lands on the provider before the visible
    /// `LockState` advances. `generation` still orders concurrent seal/release calls so the
    /// gate ends up matching the latest `LockState` regardless of which hop arrives last.
    func setRelayLocked(_ locked: Bool, generation: Int) async
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
    /// JWT and blocks re-minting until a passing Optic ID. Awaits the seal *before* exposing
    /// the locked state, so the provider can't serve the cached RCE-grade JWT to a poll that
    /// ticks once the lock screen is up. Idempotent — safe to call from every window's
    /// background transition and from the launch gate.
    func lock() async {
        await sealRelay(true)
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
            await unlock()
        case let .failure(message):
            state = .failed(message)
        }
    }

    /// Force unlock without an Optic ID prompt — used right after a fresh OAuth sign-in,
    /// where the browser handoff already proved the owner. Reveals content first, then
    /// releases the relay gate so the next poll can re-mint — the release only happens here,
    /// after a completed unlock (a passing Optic ID or a just-proven OAuth handoff).
    func unlock() async {
        state = .unlocked
        await sealRelay(false)
    }

    /// Issue a seal/release to the relay gate under a fresh generation and await it landing
    /// on the actor. The generation still lets the actor settle on whichever intent was
    /// minted last, since concurrent `lock()`/`unlock()` tasks can interleave at their await
    /// points and reach the provider out of call order.
    private func sealRelay(_ sealed: Bool) async {
        relayGeneration += 1
        await relay?.setRelayLocked(sealed, generation: relayGeneration)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}
