import Foundation

/// Durable home for the in-flight handoff's `state` nonce so a cold-start
/// `superset://auth/callback` (PRD §11) still validates after the process is
/// killed mid-OAuth. The nonce is CSRF protection, not a secret, so UserDefaults
/// (the device-local presentation store, §13) is the right home — the Keychain is
/// reserved for the session token. `AuthController` depends on the protocol so the
/// persistence can be swapped in previews and tests.
protocol PendingStateStore: Sendable {
    func save(_ state: String)
    func load() -> String?
    func clear()
}

struct UserDefaultsPendingStateStore: PendingStateStore {
    private let key = "auth.pending_state"

    func save(_ state: String) {
        UserDefaults.standard.set(state, forKey: key)
    }

    func load() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
