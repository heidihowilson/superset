import XCTest
@testable import Superset

/// URL-shaping coverage for `RelayTerminalEndpoint` (T3/T4): the `wss` terminal upgrade URL
/// and the `https` `_whoowns` affinity probe must match the relay's routes and the web client
/// byte-for-byte (`TerminalConnection.buildUrl`, `primeRelayAffinity`), including the JWT
/// riding in the query string (browsers/clients can't set WS upgrade headers).
final class RelayTerminalEndpointTests: XCTestCase {
    private let endpoint = RelayTerminalEndpoint(
        relayBaseURL: URL(string: "https://relay.superset.sh")!,
        routingKey: "org_1:host_9",
        terminalId: "term-42",
        workspaceID: "ws_7"
    )

    func testWebSocketURLUsesWSSSchemeAndTerminalPath() throws {
        let url = try XCTUnwrap(endpoint.webSocketURL(token: "jwt-abc"))
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "relay.superset.sh")
        XCTAssertEqual(url.path, "/hosts/org_1:host_9/terminal/term-42")

        let items = try queryItems(url)
        XCTAssertEqual(items["workspaceId"], "ws_7")
        XCTAssertEqual(items["themeType"], "dark")
        XCTAssertEqual(items["token"], "jwt-abc")
        XCTAssertNil(items["replay"], "replay is only set on a buffer-warm reattach")
    }

    func testWebSocketURLAppendsReplayZeroWhenDisabled() throws {
        let url = try XCTUnwrap(endpoint.webSocketURL(token: "jwt-abc", replay: false))
        XCTAssertEqual(try queryItems(url)["replay"], "0")
    }

    func testWhoOwnsURLStaysHTTPSWithAffinityPath() throws {
        let url = try XCTUnwrap(endpoint.whoOwnsURL(token: "jwt-abc"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.path, "/hosts/org_1:host_9/_whoowns")
        let items = try queryItems(url)
        XCTAssertEqual(items["token"], "jwt-abc")
        XCTAssertEqual(items["workspaceId"], "ws_7")
    }

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
    }
}
