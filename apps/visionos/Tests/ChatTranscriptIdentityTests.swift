import XCTest
@testable import Superset

/// Transcript streaming-polish coverage (#76): an id-less host message must keep a stable
/// SwiftUI identity across the 2s poll (a fresh `UUID()` per decode tore the row down every
/// tick), and the transcript must expose content growth so the view can auto-scroll when a
/// streaming final message extends in place under the same id.
final class ChatTranscriptIdentityTests: XCTestCase {
    private func decodeTranscript(_ json: String) throws -> ChatTranscript {
        try JSONDecoder().decode(ChatTranscript.self, from: Data(json.utf8))
    }

    /// The same id-less message decoded twice keeps the same id — identity is derived from
    /// content, not a per-decode `UUID()`, so SwiftUI doesn't rebuild the row each poll.
    func testIdlessMessageKeepsStableIdAcrossDecodes() throws {
        let json = #"""
        {"displayState":{"isRunning":false},
         "messages":[{"role":"system","content":[{"type":"text","text":"Connected to host."}]}]}
        """#

        let first = try decodeTranscript(json)
        let second = try decodeTranscript(json)

        XCTAssertEqual(first.messages.count, 1)
        XCTAssertFalse(first.messages[0].id.isEmpty)
        XCTAssertEqual(first.messages[0].id, second.messages[0].id, "id-less identity must be deterministic across polls")
    }

    /// Two structurally identical id-less messages get distinct ids (position folded in), so
    /// `ForEach` doesn't collapse them onto one identity.
    func testIdenticalIdlessMessagesGetDistinctIds() throws {
        let json = #"""
        {"displayState":{"isRunning":true},
         "messages":[
           {"role":"system","content":[{"type":"text","text":"working"}]},
           {"role":"system","content":[{"type":"text","text":"working"}]}
         ]}
        """#

        let transcript = try decodeTranscript(json)

        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertNotEqual(transcript.messages[0].id, transcript.messages[1].id, "duplicate id-less messages must stay distinct")
    }

    /// A host-provided id is honored verbatim — the fallback only applies when none is sent,
    /// and position is never folded into a real id.
    func testHostProvidedIdIsPreserved() throws {
        let json = #"""
        {"displayState":{"isRunning":false},
         "messages":[{"id":"msg_42","role":"assistant","content":[{"type":"text","text":"hi"}]}]}
        """#

        let transcript = try decodeTranscript(json)

        XCTAssertEqual(transcript.messages.first?.id, "msg_42")
    }

    /// The same host-id'd message at the same position keeps its id even as it streams in
    /// place — the scroll signal (content length) is what changes, not identity.
    func testStreamingMessageKeepsIdWhileContentGrows() throws {
        let short = try decodeTranscript(#"""
        {"displayState":{"isRunning":true},
         "messages":[{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hel"}]}]}
        """#)
        let grown = try decodeTranscript(#"""
        {"displayState":{"isRunning":true},
         "messages":[{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hello world"}]}]}
        """#)

        XCTAssertEqual(short.messages.first?.id, grown.messages.first?.id, "in-place growth must not change identity")
        XCTAssertGreaterThan(
            grown.messages.first?.contentLength ?? 0,
            short.messages.first?.contentLength ?? 0,
            "content length must grow so the view can auto-scroll on in-place streaming"
        )
    }

    /// `contentLength` counts prose (text + reasoning) and ignores tool/attachment parts.
    func testContentLengthCountsProseOnly() {
        let message = ChatMessage(
            id: "m",
            role: .assistant,
            content: [
                .text("abcd"),
                .reasoning("ef"),
                .tool(ChatToolPart(name: "bash", isResult: false, payload: nil)),
                .attachment(name: "a.png", mediaType: "image/png"),
            ]
        )

        XCTAssertEqual(message.contentLength, 6)
    }

    /// A round-trip through the cache (encode → decode) preserves the derived id, so a
    /// re-painted cached transcript keeps the identity the live poll produced.
    func testDerivedIdSurvivesCacheRoundTrip() throws {
        let original = try decodeTranscript(#"""
        {"displayState":{"isRunning":false},
         "messages":[{"role":"system","content":[{"type":"text","text":"Connected."}]}]}
        """#)

        let data = try JSONEncoder().encode(original)
        let reloaded = try JSONDecoder().decode(ChatTranscript.self, from: data)

        XCTAssertEqual(original.messages.first?.id, reloaded.messages.first?.id, "cached identity must match the live-decoded one")
    }
}
