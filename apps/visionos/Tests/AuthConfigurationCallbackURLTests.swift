import XCTest
@testable import Superset

/// Coverage for `AuthConfiguration.callbackURL`, which builds the deep-link URL by
/// interpolating mutable components. The default config parses; a config whose host is
/// invalid must return `nil` so a caller can fail the flow rather than trap on a force-unwrap.
final class AuthConfigurationCallbackURLTests: XCTestCase {
    func testDefaultConfigBuildsCallbackURL() {
        XCTAssertEqual(AuthConfiguration.default.callbackURL, URL(string: "superset://auth/callback"))
    }

    func testInvalidHostYieldsNilInsteadOfTrapping() {
        let configuration = AuthConfiguration(
            apiBaseURL: URL(string: "https://api.superset.sh")!,
            relayBaseURL: URL(string: "https://relay.superset.sh")!,
            callbackScheme: "superset",
            callbackHost: "invalid host",
            callbackPath: "/callback"
        )

        XCTAssertNil(configuration.callbackURL)
    }
}
