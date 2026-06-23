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
