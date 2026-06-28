import XCTest
@testable import Superset

/// Coverage for the T2 terminal-provisioning host calls on `HostServiceClient`
/// (`terminal.createSession` POST, `terminal.listSessions` GET): the relay host path + SuperJSON
/// envelope, the `terminalId` threaded out of the create result, and the tolerant
/// `HostTerminalSession` decode for the list. Mirrors `host-client.ts`'s `createHostTerminal`
/// /`listHostTerminals`.
final class HostServiceClientTerminalTests: XCTestCase {
    private func makeClient(http: HTTPPerforming) -> HostServiceClient {
        HostServiceClient(
            configuration: .default,
            http: http,
            tokenProvider: makeRelayTokenProvider(http: http),
            routingKey: "org:host"
        )
    }

    func testCreateTerminalSessionPostsAndReturnsTerminalId() async throws {
        let http = TerminalStubHTTP(hostBody: Data(#"{"result":{"data":{"json":{"terminalId":"term-7","status":"running"}}}}"#.utf8))
        let client = makeClient(http: http)

        let terminalId = try await client.createTerminalSession(workspaceID: "ws_1")
        XCTAssertEqual(terminalId, "term-7")

        let request = try XCTUnwrap(http.hostRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(
            try XCTUnwrap(request.url).path.contains("hosts/org:host/trpc/terminal.createSession"),
            "expected the relay terminal.createSession path"
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try Self.envelopedJSON(body)
        XCTAssertEqual(json["workspaceId"] as? String, "ws_1")
    }

    func testListTerminalSessionsGetsAndDecodesTolerantly() async throws {
        // The second row omits `exited`/`title` — the tolerant decode must default them, not
        // fail the whole list.
        let body = #"""
        {"result":{"data":{"json":{"sessions":[
          {"terminalId":"a","workspaceId":"ws_1","exited":true,"title":"build"},
          {"terminalId":"b"}
        ]}}}}
        """#
        let http = TerminalStubHTTP(hostBody: Data(body.utf8))
        let client = makeClient(http: http)

        let sessions = try await client.listTerminalSessions(workspaceID: "ws_1")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0], HostTerminalSession(terminalId: "a", workspaceId: "ws_1", exited: true, title: "build"))
        XCTAssertEqual(sessions[1], HostTerminalSession(terminalId: "b", workspaceId: nil, exited: false, title: nil))

        let request = try XCTUnwrap(http.hostRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(url.path.contains("hosts/org:host/trpc/terminal.listSessions"))
        let input = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "input" })?.value
        )
        let json = try Self.envelopedJSON(Data(input.utf8))
        XCTAssertEqual(json["workspaceId"] as? String, "ws_1")
    }

    private static func envelopedJSON(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["json"] as? [String: Any], "the input must be wrapped in {\"json\": …}")
    }
}

/// A capturing `HTTPPerforming` that answers the `/api/auth/token` mint (so the bearer seam
/// authorizes) and records the host-service request, returning a fixed 200 body for the
/// terminal call under test.
private final class TerminalStubHTTP: HTTPPerforming, @unchecked Sendable {
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
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (hostBody, response)
    }
}
