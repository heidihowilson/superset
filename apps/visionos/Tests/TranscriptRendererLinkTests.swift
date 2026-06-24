import JavaScriptCore
import XCTest

@testable import Superset

/// Guards the transcript WebView's inline link rule (#143). The renderer's `inline()`
/// once captured the markdown link URL but discarded it, so every anchor pointed at `#`
/// and real PR/docs links rendered dead. These exercise the pure `rendererCore` JS in a
/// JSContext — no WKWebView/DOM — and assert the captured destination survives, escaped
/// and scheme-hardened.
final class TranscriptRendererLinkTests: XCTestCase {
    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        var thrown: JSValue?
        context.exceptionHandler = { _, value in thrown = value }
        context.evaluateScript(TranscriptContentWebView.rendererCore)
        if let thrown { XCTFail("rendererCore failed to evaluate: \(thrown)") }
        return context
    }

    private func inline(_ markdown: String, in context: JSContext) throws -> String {
        let function = try XCTUnwrap(context.objectForKeyedSubscript("inline"))
        let result = try XCTUnwrap(function.call(withArguments: [markdown]))
        return try XCTUnwrap(result.toString())
    }

    func testLinkEmitsCapturedHrefNotHash() throws {
        let context = try makeContext()
        let html = try inline("[text](https://x)", in: context)

        XCTAssertTrue(html.contains("href=\"https://x\""), "expected captured URL as href, got: \(html)")
        XCTAssertFalse(html.contains("href=\"#\""), "URL must not collapse to a dead anchor, got: \(html)")
        XCTAssertTrue(html.contains(">text</a>"), "link text must be preserved, got: \(html)")
    }

    func testLinkHardensTargetAndRel() throws {
        let context = try makeContext()
        let html = try inline("[docs](https://superset.sh/docs)", in: context)

        XCTAssertTrue(html.contains("target=\"_blank\""), "anchor should open out-of-surface, got: \(html)")
        XCTAssertTrue(html.contains("rel=\"noopener noreferrer\""), "anchor rel should be hardened, got: \(html)")
    }

    func testHrefQuotesAreNeutralised() throws {
        let context = try makeContext()
        let html = try inline("[x](https://x/\"onmouseover=alert(1))", in: context)

        XCTAssertFalse(html.contains("href=\"https://x/\"onmouseover"), "raw quote must not break the attribute, got: \(html)")
        XCTAssertTrue(html.contains("&quot;"), "embedded quote should be entity-escaped, got: \(html)")
    }

    func testDangerousSchemeCollapsesToHash() throws {
        let context = try makeContext()
        let html = try inline("[x](javascript:alert(1))", in: context)

        XCTAssertTrue(html.contains("href=\"#\""), "javascript: scheme must be dropped to #, got: \(html)")
        XCTAssertFalse(html.lowercased().contains("href=\"javascript"), "javascript: must never reach href, got: \(html)")
    }
}
