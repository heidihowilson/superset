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

    init(api: AuthAPIClient) {
        self.api = api
    }

    func token() async throws -> String {
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
}
