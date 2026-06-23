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

/// Coverage for the dead/revoked-session re-auth path (#67): a 401 that no re-mint can
/// recover must drop the session and drive the app back to sign-in, not poll stale data
/// forever. Mirrors the production wiring (`AuthController.init` → the shared
/// `RelayTokenProvider`) so the transport → handler → `AuthController` chain is exercised
/// end-to-end.
final class SessionExpiryTests: XCTestCase {
    /// Drain queued main-actor work until `condition` holds (or a bounded number of yields
    /// elapse), so a `Task { @MainActor … }` hop scheduled by the off-actor transport runs
    /// before we assert on it — without a flaky fixed sleep.
    @MainActor
    private func drain(until condition: @autoclosure () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }

    /// A `mintRelayJWT` 401 — the session token itself is revoked, so the mint that has no
    /// refresh endpoint fails — surfaces `sessionExpired` and forces the app signed-out.
    @MainActor
    func testMintUnauthorizedForcesSignedOut() async throws {
        let auth = makeSignedInAuthController()
        XCTAssertEqual(auth.status, .signedIn)

        let provider = makeRelayTokenProvider(http: StatusHTTP(status: 401))
        provider.setSessionExpiredHandler { [weak auth] in
            Task { @MainActor in auth?.handleSessionExpired() }
        }

        do {
            _ = try await provider.token()
            XCTFail("expected sessionExpired when the relay-JWT mint 401s")
        } catch AuthError.sessionExpired {
            // expected
        }

        await drain(until: auth.status == .signedOut)
        XCTAssertEqual(auth.status, .signedOut, "a dead session must surface sign-in")
        XCTAssertNil(auth.token)
    }

    /// A host call that 401s even on a freshly minted JWT (the call *and* the re-mint both
    /// 401) is the "second consecutive 401" — the session is dead, so it surfaces
    /// `sessionExpired` and forces signed-out rather than retrying forever.
    @MainActor
    func testHostDoubleUnauthorizedForcesSignedOut() async throws {
        let auth = makeSignedInAuthController()
        XCTAssertEqual(auth.status, .signedIn)

        let http = RelayUnauthorizedHTTP()
        let provider = makeRelayTokenProvider(http: http)
        provider.setSessionExpiredHandler { [weak auth] in
            Task { @MainActor in auth?.handleSessionExpired() }
        }
        let client = HostServiceClient(
            configuration: .default,
            http: http,
            tokenProvider: provider,
            routingKey: "org:host"
        )

        do {
            _ = try await client.fetchSnapshot(sessionID: "s", workspaceID: "w")
            XCTFail("expected sessionExpired after the host rejects a freshly minted JWT")
        } catch AuthError.sessionExpired {
            // expected
        }

        XCTAssertEqual(http.hostCalls, 2, "the host call should be retried once on the first 401")
        XCTAssertEqual(http.mintCalls, 2, "the retry must re-mint a fresh JWT")
        await drain(until: auth.status == .signedOut)
        XCTAssertEqual(auth.status, .signedOut, "a dead session must surface sign-in")
        XCTAssertNil(auth.token)
    }

    /// `handleSessionExpired` runs the full signed-out side effects (the cache reset) and is
    /// idempotent: a no-op once already signed out, so the many poll loops that all hit the
    /// dead session collapse to a single transition.
    @MainActor
    func testHandleSessionExpiredResetsAndIsIdempotent() async {
        let auth = makeSignedInAuthController()
        XCTAssertEqual(auth.status, .signedIn)

        var resetCount = 0
        auth.onSignedOut = { resetCount += 1 }

        auth.handleSessionExpired()
        XCTAssertEqual(auth.status, .signedOut)
        XCTAssertNil(auth.token)
        XCTAssertEqual(resetCount, 1, "the signed-out cache reset must run")

        auth.handleSessionExpired()
        XCTAssertEqual(auth.status, .signedOut)
        XCTAssertEqual(resetCount, 1, "a second expiry while signed out must be a no-op")
    }
}
