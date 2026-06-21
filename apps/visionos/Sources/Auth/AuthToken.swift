import Foundation

/// The bearer credential obtained from the handoff: a better-auth session-table
/// token (≈30-day expiry, ADR-0005) plus its expiry. Sent as
/// `Authorization: Bearer <value>` on every API/tRPC call. Persisted in the
/// Keychain — it is a high-value secret (PRD §13).
struct AuthToken: Codable, Equatable, Sendable {
    let value: String
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= Date()
    }
}

/// Thread-safe holder shared between the `@MainActor` `AuthController` and the
/// `Sendable` `AuthAPIClient`, so the bearer seam can read the current token from a
/// `Sendable` closure without hopping back to the main actor on every request.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: AuthToken?

    var value: AuthToken? {
        get { lock.withLock { token } }
        set { lock.withLock { token = newValue } }
    }
}
