import Foundation
@testable import Superset

/// One-shot async rendezvous. `signal()` and `wait()` meet regardless of which lands
/// first, so a test can block a fake mid-flight and release it on cue. Lock-guarded so
/// the stored continuation is safe to touch from the test task and the mint task at once.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if signaled {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        guard !signaled else { lock.unlock(); return }
        signaled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// A fake `HTTPPerforming` that answers the `/api/auth/token` mint with a queued token and
/// counts calls. The first mint parks on `release` after announcing itself via `entered`,
/// so a test can land a `setLocked` *during* an in-flight mint (the mint-vs-seal TOCTOU,
/// #62 case 2). Later mints return immediately, so the post-unlock re-mint isn't blocked.
final class MintGateHTTP: HTTPPerforming, @unchecked Sendable {
    let entered = AsyncGate()
    let release = AsyncGate()
    private let lock = NSLock()
    private var tokens: [String]
    private var calls = 0

    init(tokens: [String]) { self.tokens = tokens }

    var callCount: Int { lock.withLock { calls } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index: Int = lock.withLock {
            let current = calls
            calls += 1
            return current
        }
        if index == 0 {
            entered.signal()
            await release.wait()
        }
        return try Self.tokenResponse(nextToken(at: index), for: request)
    }

    private func nextToken(at index: Int) -> String {
        lock.withLock { tokens.isEmpty ? "" : tokens[min(index, tokens.count - 1)] }
    }

    static func tokenResponse(_ token: String, for request: URLRequest) throws -> (Data, URLResponse) {
        let body = try JSONEncoder().encode(["token": token])
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

/// A non-blocking `HTTPPerforming` that returns queued mint tokens in order (clamping to the
/// last once exhausted) and counts calls — for the cases that don't need mid-mint timing.
final class StubMintHTTP: HTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var calls = 0

    init(tokens: [String]) { self.tokens = tokens }

    var callCount: Int { lock.withLock { calls } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let token: String = lock.withLock {
            let value = tokens.isEmpty ? "" : tokens[min(calls, tokens.count - 1)]
            calls += 1
            return value
        }
        return try MintGateHTTP.tokenResponse(token, for: request)
    }
}

/// Build a `RelayTokenProvider` over a fake transport with a valid session token, so the
/// bearer seam authorizes and the mint reaches the fake (never the network).
func makeRelayTokenProvider(http: HTTPPerforming) -> RelayTokenProvider {
    let box = TokenBox()
    box.value = AuthToken(value: "session-token", expiresAt: Date(timeIntervalSinceNow: 3600))
    let api = AuthAPIClient(configuration: .default, http: http) { box.value }
    return RelayTokenProvider(api: api)
}

/// A fake `HTTPPerforming` that answers every request with a fixed HTTP status and empty
/// body — used to drive the dead-session 401 paths (#67) where the response code, not the
/// payload, is what matters.
final class StatusHTTP: HTTPPerforming, @unchecked Sendable {
    private let status: Int

    init(status: Int) { self.status = status }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data(), response)
    }
}

/// A fake `HTTPPerforming` that mints relay JWTs successfully (`/api/auth/token` → 200) but
/// 401s every host-service relay call — the "freshly minted JWT still rejected" shape that
/// proves the session itself is dead (#67), so a host call re-mints once and then surfaces
/// `sessionExpired` on the second consecutive 401.
final class RelayUnauthorizedHTTP: HTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var mintCount = 0
    private var hostCount = 0

    var mintCalls: Int { lock.withLock { mintCount } }
    var hostCalls: Int { lock.withLock { hostCount } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/api/auth/token") {
            lock.withLock { mintCount += 1 }
            return try MintGateHTTP.tokenResponse("relay-jwt", for: request)
        }
        lock.withLock { hostCount += 1 }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        return (Data(), response)
    }
}

/// No-op `WebAuthenticating` so an `AuthController` can be built without a live browser —
/// the session-expiry paths never open the handoff, they only drop the token.
@MainActor
final class NoopWebAuthenticator: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        throw AuthError.userCanceled
    }

    func cancel() {}
}

/// In-memory `PendingStateStore` so the controller's handoff-nonce bookkeeping stays off
/// `UserDefaults` in tests.
final class InMemoryPendingStateStore: PendingStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: String?

    func save(_ state: String) { lock.withLock { self.state = state } }
    func load() -> String? { lock.withLock { state } }
    func clear() { lock.withLock { state = nil } }
}

/// A signed-in `AuthController` over in-memory stores — the relay session-expiry handler is
/// wired in `init` exactly as production wires it, so a downstream dead-session 401 drives
/// `status` to `.signedOut`.
@MainActor
func makeSignedInAuthController() -> AuthController {
    let token = AuthToken(value: "live-session", expiresAt: .distantFuture)
    let auth = AuthController(
        tokenStore: InMemoryTokenStore(token: token),
        webAuth: NoopWebAuthenticator(),
        pendingStateStore: InMemoryPendingStateStore()
    )
    auth.restore()
    return auth
}
