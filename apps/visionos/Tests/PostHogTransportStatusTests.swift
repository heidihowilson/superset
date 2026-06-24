import XCTest
@testable import Superset

/// Coverage for HTTP-status handling on PostHog sends (#147). A 4xx/5xx from `/capture`
/// (bad key, rejected event) resolves the `data(for:)` call successfully, so without a
/// status check a dropped event is silently treated as healthy. `PostHogTransport`
/// inspects the response and reports a non-2xx through its `logFailure` seam while staying
/// best-effort — the send still completes and never throws.
final class PostHogTransportStatusTests: XCTestCase {
    /// Stubs `URLSession` so a send resolves with a caller-chosen HTTP status and no network.
    private final class StubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var statusCode = 200

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Thread-safe sink for the `logFailure` seam, capturable by a `@Sendable` closure.
    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            stored.append(message)
        }

        var messages: [String] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private func makeTransport(
        status: Int,
        recorder: FailureRecorder
    ) -> PostHogTransport {
        StubURLProtocol.statusCode = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return PostHogTransport(
            apiKey: "phc_test",
            host: URL(string: "https://telemetry.example")!,
            session: URLSession(configuration: config),
            logFailure: { message in recorder.record(message) }
        )
    }

    func testNon2xxResponseIsObservedAsFailedSend() async {
        let recorder = FailureRecorder()
        let transport = makeTransport(status: 500, recorder: recorder)

        // Completes (never throws) even though the host rejected the event.
        await transport.send(TelemetryEvent(name: "loop_tick"), distinctID: "install-1")

        XCTAssertEqual(recorder.messages.count, 1, "a 500 from /capture must be reported as a dropped send")
        XCTAssertTrue(
            recorder.messages.first?.contains("500") ?? false,
            "the logged failure should name the rejecting status so a misconfigured pipeline is diagnosable"
        )
    }

    func testSuccessfulResponseIsNotLoggedAsFailure() async {
        let recorder = FailureRecorder()
        let transport = makeTransport(status: 200, recorder: recorder)

        await transport.send(TelemetryEvent(name: "loop_tick"), distinctID: "install-1")

        XCTAssertTrue(recorder.messages.isEmpty, "a 2xx send is healthy and must not be reported as a failure")
    }
}
