import XCTest
@testable import Superset

/// Decode-robustness coverage for the list poll (#69). A tRPC error envelope returned with
/// HTTP 200, or a single row whose required field drifted, must not blank the whole browser:
/// the error-on-200 is surfaced as a failure (the store then keeps its last good list) and a
/// drifted row is skipped while its decodable siblings survive — the best-effort treatment
/// hosts already get.
final class CloudWorkspaceClientDecodeTests: XCTestCase {
    /// A drifted Workspace row (missing the required `id`) is dropped; the decodable rows
    /// still render. One drift can't take the rest of the list down with it.
    func testDriftedRowIsSkippedAndSiblingsSurvive() async throws {
        let http = RoutingTRPCHTTP(routes: [
            "api/auth/get-session": .raw(#"{"session":{"activeOrganizationId":"org1"},"user":{"email":"a@b.c"}}"#),
            "v2Project.list": .json("[]"),
            "v2Workspace.list": .json(#"""
            [
              {"id":"w1","name":"Keeper","projectId":null,"projectName":null,"hostId":null},
              {"name":"DriftedNoId","projectId":null,"projectName":null,"hostId":null}
            ]
            """#),
            "host.list": .json("[]"),
        ])
        let client = makeClient(http: http)

        let snapshot = try await client.fetchSnapshot()

        XCTAssertEqual(snapshot.workspaces.map(\.id), ["w1"], "the decodable row survives, the drifted one is skipped")
    }

    /// A tRPC error envelope on HTTP 200 from the critical list read is detected as the failure
    /// it is (`AuthError.trpcError`) rather than mis-decoded as a successful empty list — so the
    /// store's cache-first path keeps the previous rows instead of blanking.
    func testErrorEnvelopeOn200ThrowsRatherThanDecodingEmpty() async {
        let http = RoutingTRPCHTTP(routes: [
            "api/auth/get-session": .raw(#"{"session":{"activeOrganizationId":"org1"},"user":{"email":"a@b.c"}}"#),
            "v2Project.list": .json("[]"),
            "v2Workspace.list": .raw(#"{"error":{"json":{"message":"UNAUTHORIZED"}}}"#),
            "host.list": .json("[]"),
        ])
        let client = makeClient(http: http)

        do {
            _ = try await client.fetchSnapshot()
            XCTFail("expected a tRPC error envelope on 200 to throw, not decode as an empty list")
        } catch let AuthError.trpcError(message) {
            XCTAssertEqual(message, "UNAUTHORIZED")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func makeClient(http: HTTPPerforming) -> CloudWorkspaceClient {
        let token = AuthToken(value: "session-token", expiresAt: Date(timeIntervalSinceNow: 3600))
        let api = AuthAPIClient(configuration: .default, http: http) { token }
        return CloudWorkspaceClient(api: api)
    }
}

/// A fake `HTTPPerforming` that answers by matching the request path against route keys
/// (a substring match, so `v2Workspace.list` matches `/api/trpc/v2Workspace.list?input=…`),
/// wrapping list/scalar bodies in the SuperJSON tRPC success envelope and returning raw
/// bodies verbatim — enough to drive `CloudWorkspaceClient.fetchSnapshot` offline.
private final class RoutingTRPCHTTP: HTTPPerforming, @unchecked Sendable {
    enum Body {
        /// A tRPC payload to wrap in `{"result":{"data":{"json": … }}}`.
        case json(String)
        /// A verbatim body (a non-tRPC endpoint, or a hand-built error envelope).
        case raw(String)
    }

    private let routes: [String: Body]

    init(routes: [String: Body]) { self.routes = routes }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.absoluteString ?? ""
        guard let (_, body) = routes.first(where: { path.contains($0.key) }) else {
            return (Data(), Self.response(for: request, status: 404))
        }
        let payload: String
        switch body {
        case let .json(json): payload = #"{"result":{"data":{"json":\#(json)}}}"#
        case let .raw(raw): payload = raw
        }
        return (Data(payload.utf8), Self.response(for: request, status: 200))
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
