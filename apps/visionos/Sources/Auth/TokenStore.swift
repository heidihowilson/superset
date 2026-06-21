import Foundation
import Security

/// Persistence seam for the session token. `AuthController` depends on the protocol
/// so the production `KeychainTokenStore` can be swapped for `InMemoryTokenStore`
/// in previews and tests.
protocol TokenStore: Sendable {
    func load() throws -> AuthToken?
    func save(_ token: AuthToken) throws
    func clear() throws
}

/// Stores the session token in the Keychain as a generic password (PRD §13 — the
/// token is a high-value secret, never UserDefaults). The value is the JSON-encoded
/// `AuthToken`; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps it on this
/// device and available to background refreshes after the first unlock.
struct KeychainTokenStore: TokenStore {
    let service: String
    let account: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "sh.superset.visionos").session",
         account: String = "session-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> AuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.keychain(status: status)
        }
        return try JSONDecoder().decode(AuthToken.self, from: data)
    }

    func save(_ token: AuthToken) throws {
        let data = try JSONEncoder().encode(token)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AuthError.keychain(status: addStatus) }
            return
        }
        throw AuthError.keychain(status: updateStatus)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status: status)
        }
    }
}

/// Non-persistent store for SwiftUI previews and unit tests.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: AuthToken?

    init(token: AuthToken? = nil) {
        self.token = token
    }

    func load() throws -> AuthToken? {
        lock.withLock { token }
    }

    func save(_ token: AuthToken) throws {
        lock.withLock { self.token = token }
    }

    func clear() throws {
        lock.withLock { token = nil }
    }
}
