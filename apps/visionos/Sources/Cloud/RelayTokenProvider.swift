import Foundation

/// Caches the short-lived relay/host JWT (`/api/auth/token`, RS256, ~1h TTL) so a
/// poll loop doesn't re-mint on every tick. Mirrors the web's `auth-token.ts`: reuse
/// until close to expiry, then re-mint.
///
/// A lock-backed `final class` (the `TokenBox` pattern), not an `actor`, so the cached
/// JWT can be dropped **synchronously** from the scene-phase background hook. An actor
/// hop — or any unstructured `Task` — might not be scheduled before the OS suspends the
/// app, stranding the RCE-grade token in memory past background. The lock lets `lock()`
/// seal and `dropRelayToken()` clear the cache inline, before the handler returns.
///
/// Security (PRD §13, ADR-0008): the JWT reaches the full host-service surface
/// (RCE-grade). `invalidate()` drops it — called on a 401 (re-mint) and on
/// backgrounding (proactive drop ahead of the ~1h revocation lag).
final class RelayTokenProvider: @unchecked Sendable {
    private let api: AuthAPIClient
    /// Conservative of the ~1h TTL, matching the web client's 50-minute reuse window.
    private let ttl: TimeInterval = 50 * 60
    private let lock = NSLock()
    private var cached: (token: String, fetchedAt: Date)?
    /// Set while the Optic ID gate is engaged (ADR-0008). Blocks minting so a poll that
    /// ticks behind the lock screen can't re-acquire the RCE-grade JWT before re-auth.
    private var locked = false
    /// Highest lock-state generation applied so far. `setLocked` ignores any update older
    /// than this so the gate's seal/release calls converge on the latest `LockState`
    /// intent even when they arrive out of call order.
    private var lockGeneration = 0

    init(api: AuthAPIClient) {
        self.api = api
    }

    func token() async throws -> String {
        // Serve a live cached token under the lock — a concurrent seal can't slip between
        // the gate check and the cache read.
        if let reusable = try lock.withLock({ () throws -> String? in
            if locked { throw RelayTokenError.locked }
            if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl {
                return cached.token
            }
            return nil
        }) {
            return reusable
        }

        let minted = try await api.mintRelayJWT()

        // A seal may have landed during the mint: honor it and discard the fresh token
        // rather than handing back an RCE-grade JWT after the gate engaged.
        return try lock.withLock {
            if locked { throw RelayTokenError.locked }
            cached = (minted, Date())
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
