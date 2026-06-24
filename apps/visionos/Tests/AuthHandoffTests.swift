import XCTest
@testable import Superset

/// Unit coverage for `AuthHandoff.parseCallback` (ADR-0005), the security-relevant pure
/// validation of the `superset://auth/callback` deep link: scheme/host/path match,
/// constant-time `state` comparison, token presence, and the ISO-8601 `expiresAt` fallback
/// to better-auth's 30-day default. Each `Result<AuthToken, AuthError>` branch is asserted,
/// plus `Data.base64URLEncodedString()` stripping `+`, `/`, and `=`.
final class AuthHandoffTests: XCTestCase {
    private let configuration = AuthConfiguration.default
    private let state = "expected-state-nonce"

    /// Builds a `superset://auth/callback` deep link with overridable scheme/host/path so the
    /// malformed-callback variants can each diverge on one component.
    private func makeCallback(
        scheme: String = "superset",
        host: String = "auth",
        path: String = "/callback",
        queryItems: [URLQueryItem]
    ) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        return components.url!
    }

    // MARK: - Success

    func testSuccessReturnsTokenWithParsedFractionalExpiry() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "session-token-abc"),
            URLQueryItem(name: "expiresAt", value: "2030-01-01T00:00:00.000Z"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.date(from: "2030-01-01T00:00:00.000Z")!
        XCTAssertEqual(result, .success(AuthToken(value: "session-token-abc", expiresAt: expected)))
    }

    /// `parseISO8601` falls through to the non-fractional formatter when the timestamp has no
    /// `.sss`, so a plain ISO-8601 expiry must still parse rather than hit the 30-day default.
    func testSuccessParsesNonFractionalExpiry() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
            URLQueryItem(name: "expiresAt", value: "2030-01-01T00:00:00Z"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        let expected = ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z")!
        XCTAssertEqual(result, .success(AuthToken(value: "tok", expiresAt: expected)))
    }

    // MARK: - expiresAt fallback to the 30-day default

    func testMissingExpiresAtFallsBackToDefaultExpiry() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        assertDefaultExpiry(result)
    }

    func testUnparseableExpiresAtFallsBackToDefaultExpiry() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
            URLQueryItem(name: "expiresAt", value: "not-a-timestamp"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        assertDefaultExpiry(result)
    }

    /// The default expiry is computed from `Date()` at parse time, so assert it lands within a
    /// minute of 30 days out rather than against a frozen instant.
    private func assertDefaultExpiry(_ result: Result<AuthToken, AuthError>, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .success(token) = result else {
            return XCTFail("expected success with default expiry, got \(result)", file: file, line: line)
        }
        let expected = Date().addingTimeInterval(60 * 60 * 24 * 30)
        XCTAssertEqual(token.expiresAt.timeIntervalSinceReferenceDate,
                       expected.timeIntervalSinceReferenceDate,
                       accuracy: 60,
                       file: file,
                       line: line)
    }

    // MARK: - State validation

    func testStateMismatchFails() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: "different-but-same-length"),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.stateMismatch))
    }

    /// A differing length must also reject — `constantTimeEquals` returns false up front rather
    /// than indexing past the shorter buffer.
    func testStateLengthMismatchFails() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: "short"),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.stateMismatch))
    }

    func testEmptyStateIsMalformed() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: ""),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.malformedCallback))
    }

    func testMissingStateIsMalformed() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.malformedCallback))
    }

    // MARK: - Token validation

    func testMissingTokenFails() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.missingToken))
    }

    func testEmptyTokenFails() {
        let url = makeCallback(queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: ""),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.missingToken))
    }

    // MARK: - Malformed callback (scheme/host/path)

    func testWrongSchemeIsMalformed() {
        let url = makeCallback(scheme: "https", queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.malformedCallback))
    }

    func testWrongHostIsMalformed() {
        let url = makeCallback(host: "evil", queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.malformedCallback))
    }

    func testWrongPathIsMalformed() {
        let url = makeCallback(path: "/not-callback", queryItems: [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "token", value: "tok"),
        ])

        let result = AuthHandoff.parseCallback(url, configuration: configuration, expectedState: state)

        XCTAssertEqual(result, .failure(.malformedCallback))
    }

    // MARK: - base64url encoding

    /// `base64URLEncodedString` must apply RFC 4648 §5: `+`→`-`, `/`→`_`, and drop `=` padding.
    /// `Data([0xFB, 0xFF])` standard-encodes to `+/8=`, exercising all three substitutions.
    func testBase64URLEncodingStripsPlusSlashAndPadding() {
        let data = Data([0xFB, 0xFF])

        XCTAssertEqual(data.base64EncodedString(), "+/8=", "fixture must contain +, /, and = to be meaningful")

        let encoded = data.base64URLEncodedString()

        XCTAssertEqual(encoded, "-_8")
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }
}
