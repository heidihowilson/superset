import XCTest
@testable import Superset

/// Request-shaping coverage for `HostServiceClient.send` (#145): the relay host path, the
/// SuperJSON `{"json": …}` envelope, and the GET-`?input=` vs POST-body method routing
/// (HostServiceClient.swift). The 401 re-mint/give-up boundary is covered separately in
/// `HostServiceClientAuthRetryTests`; this suite isolates the built `URLRequest` for one GET
/// (`fetchSnapshot`) and one POST (`sendMessage`) via a capturing `HTTPPerforming`, so a
/// regression in the envelope or method routing can't ship silently.
final class HostServiceClientRequestTests: XCTestCase {
    private func makeClient(http: HTTPPerforming) -> HostServiceClient {
        HostServiceClient(
            configuration: .default,
            http: http,
            tokenProvider: makeRelayTokenProvider(http: http),
            routingKey: "org:host"
        )
    }

    /// GET (`chat.getSnapshot`): routed to `hosts/<routingKey>/trpc/<procedure>`, the SuperJSON
    /// envelope rides in `?input=` (never a body), and the minted relay JWT stamps the Bearer
    /// header.
    func testGetRoutesEnvelopeThroughInputQueryWithBearer() async throws {
        let http = RequestCapturingHTTP(hostBody: Self.snapshotEnvelope)
        let client = makeClient(http: http)

        _ = try await client.fetchSnapshot(sessionID: "s", workspaceID: "w")

        let request = try XCTUnwrap(http.hostRequest, "the host call should have been captured")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody, "a GET must not carry a body — the input rides in ?input=")

        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(
            url.path.contains("hosts/org:host/trpc/chat.getSnapshot"),
            "expected the relay host path, got \(url.path)"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer relay-jwt")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let input = try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "input" })?.value,
            "the GET must carry the input in ?input="
        )
        let json = try Self.envelopedJSON(Data(input.utf8))
        XCTAssertEqual(json["sessionId"] as? String, "s")
        XCTAssertEqual(json["workspaceId"] as? String, "w")
    }

    /// POST (`chat.sendMessage`): routed to the same relay host path, the SuperJSON envelope
    /// rides in the JSON body (never `?input=`), `Content-Type: application/json` is set, and
    /// the Bearer header carries the JWT.
    func testPostCarriesEnvelopeInJSONBodyWithContentTypeAndBearer() async throws {
        let http = RequestCapturingHTTP(hostBody: Data())
        let client = makeClient(http: http)

        try await client.sendMessage(sessionID: "s", workspaceID: "w", content: "hi", model: nil)

        let request = try XCTUnwrap(http.hostRequest, "the host call should have been captured")
        XCTAssertEqual(request.httpMethod, "POST")

        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(
            url.path.contains("hosts/org:host/trpc/chat.sendMessage"),
            "expected the relay host path, got \(url.path)"
        )
        XCTAssertNil(url.query, "a POST must not put the input in ?input= — it rides in the body")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer relay-jwt")

        let body = try XCTUnwrap(request.httpBody, "the POST must carry the envelope in its body")
        let json = try Self.envelopedJSON(body)
        XCTAssertEqual(json["sessionId"] as? String, "s")
        XCTAssertEqual(json["workspaceId"] as? String, "w")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any], "the message payload should be threaded through")
        XCTAssertEqual(payload["content"] as? String, "hi")
    }

    /// A minimal valid relay/host success envelope so `fetchSnapshot`'s decode clears (the
    /// lenient `ChatTranscript` decoder folds an empty `json` to an empty transcript); the
    /// test asserts the *request*, so the body only needs to satisfy the decode.
    private static let snapshotEnvelope = Data(#"{"result":{"data":{"json":{}}}}"#.utf8)

    /// Parse a captured SuperJSON envelope and return the unwrapped `json` object, asserting the
    /// `{"json": …}` wrapper the relay/host transport requires.
    private static func envelopedJSON(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "expected a JSON object"
        )
        return try XCTUnwrap(object["json"] as? [String: Any], "the input must be wrapped in {\"json\": …}")
    }
}

/// A capturing `HTTPPerforming`: it answers the `/api/auth/token` mint (so the bearer seam
/// authorizes and the host call carries a real JWT) and records the host-service `URLRequest`
/// it's handed, returning a fixed 200 body — so a test can assert the *shape* of the built
/// request (path, query, body, headers) without the network.
private final class RequestCapturingHTTP: HTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: URLRequest?
    private let hostBody: Data

    init(hostBody: Data) { self.hostBody = hostBody }

    var hostRequest: URLRequest? { lock.withLock { captured } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path.hasSuffix("/api/auth/token") == true {
            return try MintGateHTTP.tokenResponse("relay-jwt", for: request)
        }
        lock.withLock { captured = request }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (hostBody, response)
    }
}
