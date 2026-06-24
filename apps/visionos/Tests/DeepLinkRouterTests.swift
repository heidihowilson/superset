import XCTest
@testable import Superset

/// Coverage for `DeepLinkRouter.route`, the pure parser for the `superset://` grammar
/// (PRD §16.2). It has several silent edge branches — case-insensitive scheme/host, the
/// exact `auth/callback` literal, first-path-component id extraction, and `nil` for
/// anything outside the grammar — that would regress unnoticed without these pins.
final class DeepLinkRouterTests: XCTestCase {
    private func route(_ string: String) -> DeepLinkRoute? {
        DeepLinkRouter.route(URL(string: string)!)
    }

    // MARK: - Happy-path scene routes

    func testWorkspaceRoute() {
        XCTAssertEqual(route("superset://workspace/ws-123"), .workspace("ws-123"))
    }

    func testProjectRoute() {
        XCTAssertEqual(route("superset://project/proj-456"), .project("proj-456"))
    }

    func testSessionRoute() {
        XCTAssertEqual(route("superset://session/sess-789"), .session("sess-789"))
    }

    func testAuthCallbackRoute() {
        let url = URL(string: "superset://auth/callback?token=abc")!
        XCTAssertEqual(DeepLinkRouter.route(url), .authCallback(url))
    }

    // MARK: - Case sensitivity

    /// Scheme and host are case-insensitive per RFC 3986, so a mixed-case link still
    /// routes — while the opaque id keeps its exact casing.
    func testMixedCaseSchemeAndHostRoutes() {
        XCTAssertEqual(route("Superset://Workspace/Id-42"), .workspace("Id-42"))
    }

    /// The host is folded to lowercase before matching the `auth` literal.
    func testMixedCaseAuthHostStillCallbacks() {
        let url = URL(string: "superset://AUTH/callback?token=x")!
        XCTAssertEqual(DeepLinkRouter.route(url), .authCallback(url))
    }

    // MARK: - Drop branches

    /// `superset://auth/<x>` is only the callback when `<x>` is exactly `callback`; any
    /// other auth path is outside the grammar.
    func testAuthWithoutCallbackPathIsDropped() {
        XCTAssertNil(route("superset://auth/refresh"))
    }

    /// The `callback` literal is case-sensitive — only the host folds case.
    func testAuthCallbackLiteralIsCaseSensitive() {
        XCTAssertNil(route("superset://auth/Callback"))
    }

    /// A host with no first path component yields no id, so it cannot open a scene.
    func testMissingWorkspaceIdIsNil() {
        XCTAssertNil(route("superset://workspace"))
    }

    /// A trailing slash leaves no non-separator path component either.
    func testTrailingSlashWorkspaceIdIsNil() {
        XCTAssertNil(route("superset://workspace/"))
    }

    /// A scheme outside the grammar is ignored so unrelated URLs pass through.
    func testForeignSchemeIsNil() {
        XCTAssertNil(route("https://workspace/ws-123"))
    }

    /// An unrecognized host is not a known scene kind.
    func testUnknownHostIsNil() {
        XCTAssertNil(route("superset://settings/general"))
    }

    // MARK: - First-path-component extraction

    /// Only the leading path component is the id; deeper segments are ignored.
    func testOnlyFirstPathComponentBecomesId() {
        XCTAssertEqual(route("superset://session/sess-1/extra/tail"), .session("sess-1"))
    }
}
