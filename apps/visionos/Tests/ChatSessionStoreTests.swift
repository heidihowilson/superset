import XCTest
@testable import Superset

/// Coverage for `ChatSessionStore`'s poll-failure mapping and cache-first refresh (#103).
/// `recordFailure` maps a 403 onto the plan-gated host-offline outcome and everything else
/// onto a drop; `refresh` is cache-first — a populated transcript is never blanked by a
/// failed poll (`loadState` stays `.loaded`), and only the empty case surfaces `.failed`.
@MainActor
final class ChatSessionStoreTests: XCTestCase {
    /// A 403 is the plan-gated host-offline state (PRD §6.3), recorded as such for the
    /// ADR-0007 telemetry rather than as a generic drop.
    func test403RecordsHostOfflinePlanGated() async {
        let store = ChatSessionStore()
        let recorder = RecorderSpy()
        store.hostCallRecorder = recorder
        let provider = StubTranscriptProvider(results: [.failure(AuthError.badServerResponse(status: 403))])
        store.bind(provider: provider, workspaceID: "w1")

        await store.refresh()

        XCTAssertEqual(recorder.outcomes.count, 1, "a failed poll records exactly one outcome")
        guard case let .hostOffline(planGated, latency) = recorder.outcomes.first?.outcome else {
            return XCTFail("a 403 maps to plan-gated host-offline, got \(String(describing: recorder.outcomes.first?.outcome))")
        }
        XCTAssertTrue(planGated, "a 403 is the plan-gated host-offline state")
        XCTAssertGreaterThan(latency, .zero, "a failed poll records the elapsed latency, not a dropped/zero duration")
        XCTAssertEqual(recorder.outcomes.first?.workspaceID, "w1", "the outcome is tagged with the bound Workspace")
    }

    /// The failure path threads the captured start instant through, so a failed poll records
    /// a non-zero latency in the host-call recorder rather than silently dropping the elapsed
    /// time of the (often slow) failed poll.
    func testFailedRefreshRecordsNonZeroLatency() async {
        let store = ChatSessionStore()
        let recorder = RecorderSpy()
        store.hostCallRecorder = recorder
        let provider = StubTranscriptProvider(results: [.failure(StubError.boom)])
        store.bind(provider: provider, workspaceID: "w1")

        await store.refresh()

        guard case let .drop(_, latency) = recorder.outcomes.first?.outcome else {
            return XCTFail("a generic failure records a drop, got \(String(describing: recorder.outcomes.first?.outcome))")
        }
        XCTAssertGreaterThan(latency, .zero, "a failed poll records a non-zero latency")
    }

    /// Any non-403 failure (transport/decoding/other server error) is a drop, carrying the
    /// error description as its reason.
    func testGenericErrorRecordsDrop() async {
        let store = ChatSessionStore()
        let recorder = RecorderSpy()
        store.hostCallRecorder = recorder
        let provider = StubTranscriptProvider(results: [.failure(StubError.boom)])
        store.bind(provider: provider, workspaceID: "w1")

        await store.refresh()

        XCTAssertEqual(recorder.outcomes.count, 1, "a failed poll records exactly one outcome")
        guard case .drop = recorder.outcomes.first?.outcome else {
            return XCTFail("a generic error must map to .drop, got \(String(describing: recorder.outcomes.first?.outcome))")
        }
    }

    /// Cache-first: once a transcript is loaded, a subsequent failing poll keeps it on screen
    /// and leaves `loadState` at `.loaded` — the M0c gate's core. The failure still records an
    /// outcome (here a drop) so the resilience telemetry sees the dropped poll.
    func testPopulatedTranscriptSurvivesFailingPoll() async {
        let store = ChatSessionStore()
        let recorder = RecorderSpy()
        store.hostCallRecorder = recorder
        let loaded = ChatTranscript(
            displayState: .idle,
            messages: [ChatMessage(id: "m1", role: .assistant, content: [.text("hello")])]
        )
        let provider = StubTranscriptProvider(results: [
            .success(loaded),
            .failure(AuthError.badServerResponse(status: 500)),
        ])
        store.bind(provider: provider, workspaceID: "w1")

        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded, "a successful poll loads the transcript")
        XCTAssertEqual(store.transcript, loaded)

        await store.refresh()
        XCTAssertEqual(store.loadState, .loaded, "a failed poll must not blank a populated transcript")
        XCTAssertEqual(store.transcript, loaded, "the last good transcript is retained on a failed poll")
        guard case .drop = recorder.outcomes.last?.outcome else {
            return XCTFail("the failing poll must record a drop, got \(String(describing: recorder.outcomes.last?.outcome))")
        }
    }

    /// With no cached transcript, a failed poll has nothing to keep, so the empty state goes
    /// `.failed` with the user-facing copy.
    func testEmptyTranscriptFailureSetsFailed() async {
        let store = ChatSessionStore()
        let provider = StubTranscriptProvider(results: [.failure(AuthError.badServerResponse(status: 500))])
        store.bind(provider: provider, workspaceID: "w1")

        await store.refresh()

        guard case .failed = store.loadState else {
            return XCTFail("an empty transcript + failure must surface .failed, got \(store.loadState)")
        }
        XCTAssertTrue(store.transcript.isEmpty, "a failed poll leaves the empty transcript empty")
    }
}

/// A `ChatTranscriptProviding` stub that yields a scripted sequence of results, one per
/// `fetchTranscript` call. `@unchecked Sendable` with a lock because the protocol is
/// `Sendable` and `fetchTranscript` may run off the main actor.
private final class StubTranscriptProvider: ChatTranscriptProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ChatTranscript, Error>]

    init(results: [Result<ChatTranscript, Error>]) {
        self.results = results
    }

    func fetchTranscript() async throws -> ChatTranscript {
        let next: Result<ChatTranscript, Error> = lock.withLock {
            results.isEmpty ? .failure(StubError.exhausted) : results.removeFirst()
        }
        return try next.get()
    }
}

/// A main-actor-isolated spy for the `HostCallRecording` sink (which is `@MainActor`), so a
/// test reads the recorded outcomes without crossing an isolation boundary.
@MainActor
private final class RecorderSpy: HostCallRecording {
    private(set) var outcomes: [(outcome: HostCallOutcome, workspaceID: String)] = []

    func record(_ outcome: HostCallOutcome, workspaceID: String) {
        outcomes.append((outcome, workspaceID))
    }
}

/// Throwaway errors to drive the failure paths: `boom` is a generic (non-`AuthError`) failure,
/// `exhausted` guards against a test asking for more polls than it scripted.
private enum StubError: Error {
    case boom
    case exhausted
}
