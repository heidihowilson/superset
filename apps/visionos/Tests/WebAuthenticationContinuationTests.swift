import AuthenticationServices
import UIKit
import XCTest
@testable import Superset

/// Unit coverage for the sign-in hang (#65): `WebAuthenticationSessionAuthenticator` must
/// resolve its `withCheckedThrowingContinuation` on every terminal path — a missing
/// presentation anchor, a `start()` that returns `false`, a failing/cancelled session, and
/// an explicit `cancel()` — instead of leaking it into a forever-spinner. The `WebAuthSession`
/// and anchor seams let each path run without a live browser or key window. A leaked
/// continuation surfaces here as a test that never returns.
@MainActor
final class WebAuthenticationContinuationTests: XCTestCase {
    private let url = URL(string: "https://example.com/connect")!
    private let scheme = "superset"

    /// Builds an authenticator wired to `fake`, with a present-able anchor by default so
    /// tests reach the session; pass `anchor: nil` to drive the missing-anchor path.
    private func makeAuthenticator(
        _ fake: FakeWebAuthSession,
        anchor: ASPresentationAnchor? = UIWindow()
    ) -> WebAuthenticationSessionAuthenticator {
        WebAuthenticationSessionAuthenticator(
            makeSession: { _, _, completion in
                fake.completion = completion
                return fake
            },
            resolveAnchor: { anchor }
        )
    }

    /// No presentable anchor must resume-throwing up front — never start a session that can
    /// never resume (the fabricated-`ASPresentationAnchor()` hang).
    func testMissingAnchorThrowsCannotPresentBrowser() async {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake, anchor: nil)

        await XCTAssertThrowsErrorAsync(try await auth.authenticate(url: url, callbackScheme: scheme)) { error in
            XCTAssertEqual(error as? AuthError, .cannotPresentBrowser)
        }
        XCTAssertFalse(fake.didStart, "must not start a session when there is no anchor")
    }

    /// `start()` returning `false` (the session can't present, completion never fires) must
    /// resume-throwing rather than hang.
    func testStartFailureThrowsCannotPresentBrowser() async {
        let fake = FakeWebAuthSession(startResult: false)
        let auth = makeAuthenticator(fake)

        await XCTAssertThrowsErrorAsync(try await auth.authenticate(url: url, callbackScheme: scheme)) { error in
            XCTAssertEqual(error as? AuthError, .cannotPresentBrowser)
        }
        XCTAssertTrue(fake.didStart)
    }

    /// A session that ends in an error resolves the continuation with that error.
    func testSessionErrorPropagates() async {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake)

        let task = Task { try await auth.authenticate(url: url, callbackScheme: scheme) }
        await fake.started.wait()
        fake.completion?(nil, AuthError.badServerResponse(status: 500))

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? AuthError, .badServerResponse(status: 500))
        }
    }

    /// A session whose completion reports neither URL nor error is a malformed callback,
    /// not a hang.
    func testMissingCallbackThrowsMalformed() async {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake)

        let task = Task { try await auth.authenticate(url: url, callbackScheme: scheme) }
        await fake.started.wait()
        fake.completion?(nil, nil)

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? AuthError, .malformedCallback)
        }
    }

    /// A captured callback URL resolves the continuation successfully.
    func testSuccessfulCallbackResolves() async throws {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake)
        let callback = URL(string: "superset://auth/callback?token=abc")!

        let task = Task { try await auth.authenticate(url: url, callbackScheme: scheme) }
        await fake.started.wait()
        fake.completion?(callback, nil)

        let result = try await task.value
        XCTAssertEqual(result, callback)
    }

    /// `cancel()` tears down the in-flight session and resumes the continuation as
    /// `userCanceled`, returning the caller to a retryable state.
    func testCancelResumesAsUserCanceled() async {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake)

        let task = Task { try await auth.authenticate(url: url, callbackScheme: scheme) }
        await fake.started.wait()
        auth.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? AuthError, .userCanceled)
        }
        XCTAssertTrue(fake.didCancel, "cancel() must tear down the underlying session")
    }

    /// A late completion after `cancel()` already resolved the continuation is a no-op,
    /// not a double-resume crash.
    func testCompletionAfterCancelIsNoOp() async {
        let fake = FakeWebAuthSession(startResult: true)
        let auth = makeAuthenticator(fake)

        let task = Task { try await auth.authenticate(url: url, callbackScheme: scheme) }
        await fake.started.wait()
        auth.cancel()
        _ = try? await task.value
        // A stray completion from the torn-down session must not resume the (already gone)
        // continuation a second time.
        fake.completion?(URL(string: "superset://auth/callback?token=late")!, nil)
    }
}

/// A `WebAuthSession` double that records `start()`/`cancel()` and hands its completion
/// back to the test so each terminal path can be driven on cue. `started` lets the test
/// await the `authenticate` task reaching `start()` before it fires the completion.
@MainActor
private final class FakeWebAuthSession: WebAuthSession {
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    var prefersEphemeralWebBrowserSession = false

    var completion: ((URL?, Error?) -> Void)?
    private(set) var didStart = false
    private(set) var didCancel = false
    let started = AsyncGate()
    private let startResult: Bool

    init(startResult: Bool) {
        self.startResult = startResult
    }

    func start() -> Bool {
        didStart = true
        started.signal()
        return startResult
    }

    func cancel() {
        didCancel = true
    }
}

/// Async-friendly `XCTAssertThrowsError`: awaits the throwing expression and runs the
/// handler against the caught error, failing if none is thrown.
@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
