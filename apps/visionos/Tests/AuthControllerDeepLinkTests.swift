import XCTest
@testable import Superset

/// Coverage for `AuthController.handleDeepLink`'s cold-start recovery contract (#106): the
/// durable nonce in `pendingStateStore` must survive a `complete` that throws, so a
/// re-delivered cold-start callback can still validate. A successful `complete` must clear it.
@MainActor
final class AuthControllerDeepLinkTests: XCTestCase {
    private let configuration = AuthConfiguration.default
    private let nonce = "expected-state-nonce"

    private func makeController(
        pendingStateStore: PendingStateStore
    ) -> AuthController {
        AuthController(
            configuration: configuration,
            tokenStore: InMemoryTokenStore(),
            webAuth: NoopWebAuthenticator(),
            pendingStateStore: pendingStateStore
        )
    }

    /// A `superset://auth/callback` deep link with an optional token, so the success path
    /// supplies one and the throw path omits it (`AuthError.missingToken`).
    private func callback(token: String?) -> URL {
        var components = URLComponents()
        components.scheme = "superset"
        components.host = "auth"
        components.path = "/callback"
        var items = [URLQueryItem(name: "state", value: nonce)]
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items
        return components.url!
    }

    /// When `complete` throws, the recovery nonce stays in durable storage so a re-delivered
    /// cold-start callback can validate — the whole point of `handleDeepLink`.
    func testFailedCompletionKeepsPendingNonce() {
        let store = InMemoryPendingStateStore()
        store.save(nonce)
        let auth = makeController(pendingStateStore: store)

        auth.handleDeepLink(callback(token: nil))

        XCTAssertEqual(store.load(), nonce)
    }

    /// A successful `complete` clears the nonce — recovery is done, so the durable copy must
    /// not linger to validate a stale callback.
    func testSuccessfulCompletionClearsPendingNonce() {
        let store = InMemoryPendingStateStore()
        store.save(nonce)
        let auth = makeController(pendingStateStore: store)

        auth.handleDeepLink(callback(token: "session-token-abc"))

        XCTAssertNil(store.load())
    }
}
