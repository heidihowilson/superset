import XCTest
@testable import Superset

/// Coverage for `SettingsModel.switchOrganization` (#26, the PR #25 CodeRabbit follow-up):
/// the active-org switch and its follow-up session refresh are independent. Once
/// `setActiveOrganization` succeeds the org has changed server-side, so a failed refresh
/// must not be reported as a switch error — otherwise `SettingsView` keeps the stale org
/// and skips the downstream workspace refresh (it only refreshes when `switchError == nil`).
@MainActor
final class SettingsOrgSwitchTests: XCTestCase {
    /// A routing `HTTPPerforming` whose `set-active` and `get-session` outcomes are set
    /// per-test. `get-session` reports `sessionOrgID`; the org list is fixed so `load()`
    /// can reach `.loaded`, and `chat.getModels` is best-effort so an empty list is fine.
    final class OrgSwitchHTTP: HTTPPerforming, @unchecked Sendable {
        private let lock = NSLock()
        private var _sessionOrgID: String?
        private var _getSessionStatus = 200
        private var _setActiveStatus = 200
        private var _setActiveCount = 0
        private var _getSessionCount = 0

        init(sessionOrgID: String?) { _sessionOrgID = sessionOrgID }

        var sessionOrgID: String? {
            get { lock.withLock { _sessionOrgID } }
            set { lock.withLock { _sessionOrgID = newValue } }
        }
        var getSessionStatus: Int {
            get { lock.withLock { _getSessionStatus } }
            set { lock.withLock { _getSessionStatus = newValue } }
        }
        var setActiveStatus: Int {
            get { lock.withLock { _setActiveStatus } }
            set { lock.withLock { _setActiveStatus = newValue } }
        }
        var setActiveCount: Int { lock.withLock { _setActiveCount } }
        var getSessionCount: Int { lock.withLock { _getSessionCount } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let path = request.url?.path ?? ""
            let (status, body): (Int, Data) = lock.withLock {
                if path.hasSuffix("/organization/set-active") {
                    _setActiveCount += 1
                    return (_setActiveStatus, Data())
                }
                if path.hasSuffix("/get-session") {
                    _getSessionCount += 1
                    return (_getSessionStatus, Self.sessionBody(orgID: _sessionOrgID))
                }
                if path.hasSuffix("/organization/list") {
                    return (200, Self.orgsBody)
                }
                return (200, Self.modelsBody)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (body, response)
        }

        static func sessionBody(orgID: String?) -> Data {
            let session: [String: Any] = orgID.map { ["activeOrganizationId": $0] } ?? [:]
            let payload: [String: Any] = ["session": session, "user": ["email": "user@example.com"]]
            return try! JSONSerialization.data(withJSONObject: payload)
        }
        static var orgsBody: Data {
            try! JSONSerialization.data(withJSONObject: [
                ["id": "org-a", "name": "Org A"],
                ["id": "org-b", "name": "Org B"],
            ])
        }
        static var modelsBody: Data {
            try! JSONSerialization.data(withJSONObject: ["result": ["data": ["json": ["models": []]]]])
        }
    }

    private func makeModel(sessionOrgID: String?) -> (SettingsModel, OrgSwitchHTTP) {
        let http = OrgSwitchHTTP(sessionOrgID: sessionOrgID)
        let token = AuthToken(value: "session-token", expiresAt: Date(timeIntervalSinceNow: 3600))
        let api = AuthAPIClient(configuration: .default, http: http) { token }
        return (SettingsModel(api: api), http)
    }

    /// Happy path — a switch that refreshes cleanly adopts the server's new active org and
    /// reports no error, so the view runs its downstream workspace refresh.
    func testSwitchSuccessRefreshesSession() async {
        let (model, http) = makeModel(sessionOrgID: "org-a")
        await model.load()
        XCTAssertEqual(model.activeOrganizationID, "org-a")

        http.sessionOrgID = "org-b"
        await model.switchOrganization(to: "org-b")

        XCTAssertNil(model.switchError)
        XCTAssertEqual(model.activeOrganizationID, "org-b")
        XCTAssertEqual(http.setActiveCount, 1)
    }

    /// The #26 regression — `setActiveOrganization` succeeds but the follow-up `fetchSession`
    /// fails. The switch is reported successful (no error), the stale-but-valid session is
    /// retained for the next `load`/poll to reconcile, and the best-effort refresh was tried.
    func testRefreshFailureAfterSwitchIsNotReportedAsError() async {
        let (model, http) = makeModel(sessionOrgID: "org-a")
        await model.load()
        let sessionsAfterLoad = http.getSessionCount

        http.getSessionStatus = 500
        await model.switchOrganization(to: "org-b")

        XCTAssertNil(
            model.switchError,
            "a refresh failure after a successful switch must not surface as a switch error"
        )
        XCTAssertEqual(
            model.activeOrganizationID, "org-a",
            "the stale-but-valid session is retained; the next load reconciles it"
        )
        XCTAssertEqual(http.setActiveCount, 1)
        XCTAssertEqual(
            http.getSessionCount, sessionsAfterLoad + 1,
            "the switch still attempts a best-effort refresh"
        )
    }

    /// A failed `setActiveOrganization` is the real failure: it surfaces an error, leaves the
    /// active org unchanged, and never attempts the session refresh.
    func testSwitchFailureSurfacesErrorAndSkipsRefresh() async {
        let (model, http) = makeModel(sessionOrgID: "org-a")
        await model.load()
        let sessionsAfterLoad = http.getSessionCount

        http.setActiveStatus = 500
        await model.switchOrganization(to: "org-b")

        XCTAssertNotNil(model.switchError, "a failed set-active must surface an error")
        XCTAssertEqual(model.activeOrganizationID, "org-a")
        XCTAssertEqual(
            http.getSessionCount, sessionsAfterLoad,
            "no session refresh is attempted after a failed switch"
        )
    }
}
