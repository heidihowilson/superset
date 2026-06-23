import Foundation

/// Invoked when a bearer-authed call proves the stored session token itself is dead — a
/// relay-JWT mint 401, or a host call that 401s even on a freshly minted JWT. Fired off
/// the main actor from the transport; the handler hops to the main actor to drop the
/// token and surface sign-in (`AuthController.handleSessionExpired`).
typealias SessionExpiredHandler = @Sendable () -> Void

/// Caches the short-lived relay/host JWT (`/api/auth/token`, RS256, ~1h TTL) so a
/// poll loop doesn't re-mint on every tick. Mirrors the web's `auth-token.ts`: reuse
/// until close to expiry, then re-mint.
///
/// A lock-backed `final class` rather than an `actor` so the cached JWT can be dropped
/// **synchronously** from the scene-phase background hook (`dropRelayToken`) and the seal
/// can land inline within the lock transition. An actor hop — or any unstructured `Task` —
/// is not guaranteed to be scheduled before the OS suspends the app, which would strand the
/// RCE-grade token in memory past background. The lock keeps the cache read/write safe
/// across the host transport's off-main-actor poll loops.
///
/// Security (PRD §13, ADR-0008): the JWT reaches the full host-service surface
/// (RCE-grade). `invalidate()` drops it — called on a 401 (re-mint) and on
/// backgrounding (proactive drop ahead of the ~1h revocation lag).
final class RelayTokenProvider: @unchecked Sendable {
    private let api: AuthAPIClient
    /// Reads the live bearer principal (the session-token value) the relay JWT is minted
    /// from. `AuthController.setToken` updates it synchronously — before any actor hop — so
    /// the cache can be pinned to the principal it was minted under and a hit refused the
    /// instant the principal changes, independent of when the queued `invalidate()` lands.
    private let currentPrincipal: @Sendable () -> String?
    /// Conservative of the ~1h TTL, matching the web client's 50-minute reuse window.
    private let ttl: TimeInterval = 50 * 60
    private let lock = NSLock()
    private var cached: (token: String, fetchedAt: Date, principal: String?)?
    /// Set while the Optic ID gate is engaged (ADR-0008). Blocks minting so a poll that
    /// ticks behind the lock screen can't re-acquire the RCE-grade JWT before re-auth.
    private var locked = false
    /// Highest lock-state generation applied so far. `setLocked` ignores any update older
    /// than this so the gate's seal/release calls converge on the latest `LockState` intent
    /// even when they arrive out of call order.
    private var lockGeneration = 0
    /// Fired when the session token is rejected (a mint 401, or — via
    /// `notifySessionExpired()` — a host call that 401s on a freshly minted JWT). Set once
    /// at wiring time; read under the lock since the poll loops mint off the main actor.
    private var onSessionExpired: SessionExpiredHandler?

    init(api: AuthAPIClient, currentPrincipal: @escaping @Sendable () -> String?) {
        self.api = api
        self.currentPrincipal = currentPrincipal
    }

    /// Wire the forced-re-auth handler (`AuthController.handleSessionExpired`). Called once
    /// when the controller builds the shared provider, before any poll loop starts.
    func setSessionExpiredHandler(_ handler: @escaping SessionExpiredHandler) {
        lock.withLock { onSessionExpired = handler }
    }

    /// Signal a definitive session-death 401 observed downstream (the host rejected a
    /// freshly minted JWT), firing the handler exactly as a mint 401 does. Read under the
    /// lock, then called outside it so a re-auth hop can't deadlock against the cache lock.
    func notifySessionExpired() {
        let handler = lock.withLock { onSessionExpired }
        handler?()
    }

    func token() async throws -> String {
        let principal = currentPrincipal()
        // Read the gate and cache together under the lock so a concurrent seal can't slip
        // between the gate check and the cache read. The cache is pinned to the principal
        // it was minted under: a hit is refused the instant the principal changes, so a
        // sign-out/sign-in/account switch can't reuse the old RCE-grade relay JWT.
        if let reusable = try lock.withLock({ () throws -> String? in
            if locked { throw RelayTokenError.locked }
            if let cached, cached.principal == principal,
               Date().timeIntervalSince(cached.fetchedAt) < ttl {
                return cached.token
            }
            return nil
        }) {
            return reusable
        }

        let minted: String
        do {
            minted = try await api.mintRelayJWT()
        } catch AuthError.badServerResponse(status: 401) {
            // The session token itself is revoked/expired — there is no refresh endpoint,
            // so re-running the OAuth handoff is the only recovery (PRD §11).
            notifySessionExpired()
            throw AuthError.sessionExpired
        }

        // A seal may have engaged during the mint: honor it and discard the fresh JWT
        // rather than caching or returning an RCE-grade token after the gate locked.
        return try lock.withLock {
            if locked { throw RelayTokenError.locked }
            cached = (minted, Date(), principal)
            return minted
        }
    }

    func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Engage/release the Optic ID gate. Locking also drops the cached token so a stale
    /// JWT can't be served; unlocking lets the next poll re-mint after re-auth. `generation`
    /// is a monotonic token minted on the lock controller in transition order: a stale
    /// update (a lower generation arriving late) is dropped so the gate can't be left
    /// sealed after the UI has unlocked, or open before the lock has engaged.
    func setLocked(_ value: Bool, generation: Int) {
        lock.withLock {
            guard generation > lockGeneration else { return }
            lockGeneration = generation
            locked = value
            if value { cached = nil }
        }
    }
}

/// Raised when a relay-credential request is attempted while the Optic ID gate is
/// engaged. Poll loops treat it like any transient host error — keep the last good data
/// and retry on the next tick, by which point re-auth has released the gate.
enum RelayTokenError: Error {
    case locked
}
