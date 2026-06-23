import XCTest
@testable import Superset

/// Unit coverage for the relay-seal logic the #24 / PR #61 security review flagged as
/// untested. `RelayTokenProvider` is a lock-backed `final class`, so the Optic ID gate
/// (ADR-0008) is exercised deterministically here — including the mint-vs-seal TOCTOU
/// (case 2) that broke five prior attempts.
final class RelayTokenProviderTests: XCTestCase {
    /// Case 1 — while sealed, `token()` throws `.locked` and never mints. A poll that ticks
    /// behind the lock screen must not re-acquire the RCE-grade JWT.
    func testLockedTokenThrowsAndNeverMints() async {
        let http = StubMintHTTP(tokens: ["should-not-mint"])
        let provider = makeRelayTokenProvider(http: http)

        provider.setLocked(true, generation: 1)

        do {
            _ = try await provider.token()
            XCTFail("expected RelayTokenError.locked while sealed")
        } catch RelayTokenError.locked {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(http.callCount, 0, "must not mint while the gate is sealed")
    }

    /// Case 2 (the key one) — a seal that lands *during* an in-flight mint discards the
    /// freshly-minted JWT instead of caching or returning it. After unlocking, the next
    /// `token()` must re-mint (proving the in-flight token was dropped, not cached).
    func testSealDuringInFlightMintDiscardsToken() async throws {
        let http = MintGateHTTP(tokens: ["in-flight", "after-unlock"])
        let provider = makeRelayTokenProvider(http: http)

        let mintTask = Task { try await provider.token() }

        await http.entered.wait()                 // the mint is now parked in flight
        provider.setLocked(true, generation: 1)   // seal lands mid-mint
        http.release.signal()                      // let the mint complete

        do {
            _ = try await mintTask.value
            XCTFail("expected RelayTokenError.locked — the mid-mint seal must win")
        } catch RelayTokenError.locked {
            // expected: the fresh JWT is discarded, not returned
        }

        provider.setLocked(false, generation: 2)
        let token = try await provider.token()
        XCTAssertEqual(token, "after-unlock", "must re-mint, not serve the discarded token")
        XCTAssertEqual(http.callCount, 2, "the discarded in-flight token must not have been cached")
    }

    /// Case 3 — `invalidate()` (the `dropRelayToken()` background-seal path) clears the cache
    /// synchronously, so the next `token()` re-mints rather than serving the dropped JWT.
    func testInvalidateClearsCacheSynchronously() async throws {
        let http = StubMintHTTP(tokens: ["first", "second"])
        let provider = makeRelayTokenProvider(http: http)

        let first = try await provider.token()
        XCTAssertEqual(first, "first")
        let cached = try await provider.token()
        XCTAssertEqual(cached, "first")
        XCTAssertEqual(http.callCount, 1, "the second call should reuse the cached token")

        provider.invalidate()

        let reminted = try await provider.token()
        XCTAssertEqual(reminted, "second", "invalidate() must clear the cache before returning")
        XCTAssertEqual(http.callCount, 2)
    }

    /// Case 4 — generation ordering. A `setLocked` carrying a stale (lower) generation is
    /// ignored, so the gate converges on the latest `LockState` intent regardless of the
    /// order concurrent seal/release calls arrive in.
    func testGenerationOrderingIgnoresStaleUpdates() async throws {
        let http = StubMintHTTP(tokens: ["minted"])
        let provider = makeRelayTokenProvider(http: http)

        provider.setLocked(true, generation: 5)    // sealed at generation 5
        provider.setLocked(false, generation: 3)   // stale unlock — must be ignored

        do {
            _ = try await provider.token()
            XCTFail("a lower-generation unlock must not open the gate")
        } catch RelayTokenError.locked {
            // expected: still sealed
        }

        provider.setLocked(false, generation: 6)   // newest intent wins
        let token = try await provider.token()
        XCTAssertEqual(token, "minted")

        provider.setLocked(true, generation: 4)     // stale lock — can't reseal
        let again = try await provider.token()
        XCTAssertEqual(again, "minted", "a stale lock must not reseal an already-open gate")
        XCTAssertEqual(http.callCount, 1, "the open gate should keep serving the cached token")
    }
}
