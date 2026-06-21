import Foundation

/// Caches the short-lived relay/host JWT (`/api/auth/token`, RS256, ~1h TTL) so a
/// poll loop doesn't re-mint on every tick. Mirrors the web's `auth-token.ts`: reuse
/// until close to expiry, then re-mint. An `actor` because the cache is read/written
/// from the host transport off the main actor.
///
/// Security (PRD §13, ADR-0008): the JWT reaches the full host-service surface
/// (RCE-grade). `invalidate()` drops it — called on a 401 (re-mint) and on
/// backgrounding (proactive drop ahead of the ~1h revocation lag).
actor RelayTokenProvider {
    private let api: AuthAPIClient
    /// Conservative of the ~1h TTL, matching the web client's 50-minute reuse window.
    private let ttl: TimeInterval = 50 * 60
    private var cached: (token: String, fetchedAt: Date)?
    /// Set while the Optic ID gate is engaged (ADR-0008). Blocks minting so a poll that
    /// ticks behind the lock screen can't re-acquire the RCE-grade JWT before re-auth.
    private var locked = false
    /// Highest lock-state generation applied so far. `setLocked` ignores any update older
    /// than this so the gate's seal/release calls — fire-and-forget hops onto this actor —
    /// converge on the latest `LockState` intent even when they arrive out of call order.
    private var lockGeneration = 0

    init(api: AuthAPIClient) {
        self.api = api
    }

    func token() async throws -> String {
        if locked { throw RelayTokenError.locked }
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.token
        }
        let minted = try await api.mintRelayJWT()
        cached = (minted, Date())
        return minted
    }

    func invalidate() {
        cached = nil
    }

    /// Engage/release the Optic ID gate. Locking also drops the cached token so a stale
    /// JWT can't be served; unlocking lets the next poll re-mint after re-auth. `generation`
    /// is a monotonic token minted on the lock controller in transition order: a stale
    /// update (a lower generation arriving late) is dropped so the gate can't be left
    /// sealed after the UI has unlocked, or open before the lock has engaged.
    func setLocked(_ value: Bool, generation: Int) {
        guard generation > lockGeneration else { return }
        lockGeneration = generation
        locked = value
        if value { cached = nil }
    }
}

/// Raised when a relay-credential request is attempted while the Optic ID gate is
/// engaged. Poll loops treat it like any transient host error — keep the last good data
/// and retry on the next tick, by which point re-auth has released the gate.
enum RelayTokenError: Error {
    case locked
}
