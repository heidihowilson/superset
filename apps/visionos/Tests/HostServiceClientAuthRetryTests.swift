import XCTest
@testable import Superset

/// Direct transport coverage for `HostServiceClient.requestData`'s 401 handling (#67):
/// a single 401 means the cached relay JWT aged out mid-poll — drop it, re-mint, retry once
/// and succeed — while a *second* consecutive 401 (the host rejecting a freshly minted JWT)
/// means the session itself is dead, so it surfaces `sessionExpired` and fires the
/// session-expired handler. The end-to-end signed-out side effect is covered in
/// `SessionExpiryTests`; this suite isolates the transport's retry/give-up boundary.
final class HostServiceClientAuthRetryTests: XCTestCase {
    private func makeClient(http: HTTPPerforming, provider: RelayTokenProvider) -> HostServiceClient {
        HostServiceClient(
            configuration: .default,
            http: http,
            tokenProvider: provider,
            routingKey: "org:host"
        )
    }

    /// Single 401 → the cached JWT is invalidated, a fresh one is minted, and the retried
    /// host call succeeds. The second mint is the observable proof `invalidate()` dropped the
    /// cache before the retry (a still-valid cache would have been reused without re-minting).
    func testSingleUnauthorizedInvalidatesReMintsAndRetries() async throws {
        let http = RelayRetryOnceHTTP()
        let provider = makeRelayTokenProvider(http: http)
        let client = makeClient(http: http, provider: provider)

        // A void mutation: `requestData` returns the raw body undecoded, so the retry's empty
        // 200 is enough to prove the call recovered without surfacing an error.
        try await client.sendMessage(sessionID: "s", workspaceID: "w", content: "hi", model: nil)

        XCTAssertEqual(http.hostCalls, 2, "the host call should be retried once after the first 401")
        XCTAssertEqual(http.mintCalls, 2, "the retry must re-mint a fresh JWT (invalidate dropped the cache)")
    }

    /// Double 401 → the freshly minted JWT is still rejected, so the session is dead: the
    /// call throws `AuthError.sessionExpired` and fires the session-expired handler exactly
    /// once, rather than retrying forever.
    func testDoubleUnauthorizedThrowsSessionExpiredAndNotifies() async throws {
        let http = RelayUnauthorizedHTTP()
        let provider = makeRelayTokenProvider(http: http)

        let expiredCount = Counter()
        provider.setSessionExpiredHandler {
            expiredCount.increment()
        }

        let client = makeClient(http: http, provider: provider)

        do {
            _ = try await client.fetchSnapshot(sessionID: "s", workspaceID: "w")
            XCTFail("expected sessionExpired after the host rejects a freshly minted JWT")
        } catch AuthError.sessionExpired {
            // expected: the second consecutive 401 is unrecoverable
        }

        XCTAssertEqual(http.hostCalls, 2, "the host call should be retried once on the first 401")
        XCTAssertEqual(http.mintCalls, 2, "the retry must re-mint a fresh JWT before giving up")
        XCTAssertEqual(
            expiredCount.value, 1,
            "the session-expired handler must fire exactly once on the second consecutive 401"
        )
    }
}

/// Lock-backed call counter so a `@Sendable` handler can tally firings without capturing a
/// mutable `var` (Swift 6 strict concurrency).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
