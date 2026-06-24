import XCTest
@testable import Superset

/// Coverage for `ComposerStore`'s workspace-switch race guards (#98). Every async completion
/// is gated on `boundWorkspaceID`, so a late send from a previous Workspace can't clobber the
/// current one; re-binding the *same* Workspace keeps the in-progress draft while switching to
/// a *different* one resets the composer; and a failed send keeps the draft so the user can
/// retry without re-dictating. `canSend` gates the button off for a whitespace-only draft or a
/// send already in flight.
@MainActor
final class ComposerStoreTests: XCTestCase {
    /// Re-binding the same Workspace is a no-op: the draft and model the user is composing
    /// survive (e.g. a window re-appearing rebinds its own Workspace).
    func testReBindSameWorkspaceKeepsDraft() {
        let store = ComposerStore()
        let sender = StubSender()
        store.bind(sender: sender, workspaceID: "w1") {}
        store.draft = "in progress"
        store.selectedModelID = "m1"

        store.bind(sender: sender, workspaceID: "w1") {}

        XCTAssertEqual(store.draft, "in progress", "re-binding the same Workspace must keep the draft")
        XCTAssertEqual(store.selectedModelID, "m1", "re-binding the same Workspace must keep the model")
    }

    /// Binding a different Workspace resets the composer so one window never sends another
    /// Workspace's draft or model.
    func testBindDifferentWorkspaceClearsDraftAndModel() {
        let store = ComposerStore()
        let sender = StubSender()
        store.bind(sender: sender, workspaceID: "w1") {}
        store.draft = "in progress"
        store.selectedModelID = "m1"

        store.bind(sender: sender, workspaceID: "w2") {}

        XCTAssertEqual(store.draft, "", "binding a different Workspace must clear the draft")
        XCTAssertNil(store.selectedModelID, "binding a different Workspace must clear the model")
        XCTAssertEqual(store.sendState, .idle)
    }

    /// A successful send delivers the trimmed draft, clears it, returns to `.idle`, and pings
    /// `onSent` so the watch re-polls ("see the run").
    func testSuccessfulSendClearsDraftAndFiresOnSent() async {
        let store = ComposerStore()
        let sender = StubSender()
        let onSent = CallCounter()
        store.bind(sender: sender, workspaceID: "w1") { onSent.count += 1 }
        store.draft = "  hello  "

        await store.send()

        XCTAssertEqual(store.draft, "", "a successful send clears the draft")
        XCTAssertEqual(store.sendState, .idle)
        XCTAssertEqual(sender.sentMessages, ["hello"], "the trimmed draft is delivered to the sender")
        XCTAssertEqual(onSent.count, 1, "onSent fires once so the watch re-polls")
    }

    /// A failed send keeps the draft for retry, surfaces `.failed`, and does not fire `onSent`.
    func testFailedSendKeepsDraftAndSetsFailed() async {
        let store = ComposerStore()
        let sender = StubSender(sendError: StubSendError())
        let onSent = CallCounter()
        store.bind(sender: sender, workspaceID: "w1") { onSent.count += 1 }
        store.draft = "retry me"

        await store.send()

        XCTAssertEqual(store.draft, "retry me", "a failed send keeps the draft so the user can retry")
        guard case .failed = store.sendState else {
            return XCTFail("a failed send must surface .failed, got \(store.sendState)")
        }
        XCTAssertEqual(onSent.count, 0, "onSent must not fire when the send fails")
    }

    /// `canSend` is false for an empty/whitespace-only draft and true once it holds real text.
    func testCanSendFalseWhenDraftWhitespaceOnly() {
        let store = ComposerStore()
        XCTAssertFalse(store.canSend, "an empty draft is not sendable")

        store.draft = "   \n\t  "
        XCTAssertFalse(store.canSend, "a whitespace-only draft is not sendable")

        store.draft = "ship it"
        XCTAssertTrue(store.canSend, "a draft with real text is sendable")
    }

    /// `canSend` is false while a send is in flight even with a non-empty draft, so a second
    /// tap can't double-send. A gated sender parks the send mid-flight to observe `.sending`.
    func testCanSendFalseWhileSending() async {
        let store = ComposerStore()
        let sender = GatedSender()
        store.bind(sender: sender, workspaceID: "w1") {}
        store.draft = "hello"
        XCTAssertTrue(store.canSend, "a non-empty draft is sendable before the send starts")

        let sendTask = Task { await store.send() }
        await sender.entered.wait()

        XCTAssertEqual(store.sendState, .sending)
        XCTAssertFalse(store.canSend, "canSend is false mid-flight even with a non-empty draft")

        sender.release.signal()
        await sendTask.value
        XCTAssertEqual(store.sendState, .idle, "the send returns to idle once it completes")
    }

    /// A picker load from a superseded binding must be dropped (#114). An A->B->A rebind
    /// returns `boundWorkspaceID` to "A", so the workspace guard alone would let a slow
    /// fetch from the first "A" binding land its stale list. The generation guard catches
    /// it because each distinct bind bumps the generation.
    func testStaleLoadPickersFromRebindCycleIsDropped() async {
        let store = ComposerStore()
        let firstSender = GatedModelsSender(models: [ChatModel(id: "stale", name: "Stale", provider: "P")])
        store.bind(sender: firstSender, workspaceID: "A") {}

        // Start the first load; it parks inside `availableModels()`.
        let loadTask = Task { await store.loadPickers() }
        await firstSender.entered.wait()

        // Rebind A->B->A while the first fetch is in flight: `boundWorkspaceID` is "A"
        // again (matching the parked load) but the bind generation has moved on.
        store.bind(sender: StubSender(), workspaceID: "B") {}
        store.bind(sender: StubSender(), workspaceID: "A") {}

        firstSender.release.signal()
        await loadTask.value

        XCTAssertTrue(store.models.isEmpty, "a picker list from a superseded binding must be dropped")
        XCTAssertNil(store.selectedModelID, "a superseded load must not set the model selection")
    }
}

/// A `ChatSending` stub that records delivered messages and optionally throws. `@unchecked
/// Sendable` with a lock because `ChatSending` is `Sendable` and its async methods may run
/// off the main actor.
private final class StubSender: ChatSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _sentMessages: [String] = []
    private let sendError: Error?

    init(sendError: Error? = nil) {
        self.sendError = sendError
    }

    var sentMessages: [String] { lock.withLock { _sentMessages } }

    func sendMessage(_ text: String, model: String?) async throws {
        lock.withLock { _sentMessages.append(text) }
        if let sendError { throw sendError }
    }

    func availableModels() async throws -> [ChatModel] { [] }
    func availableAgentPresets() async throws -> [AgentPreset] { [] }
}

/// A `ChatSending` stub whose `sendMessage` parks until released, so a test can observe the
/// composer's mid-flight `.sending` state. `entered` fires when the send begins; `release`
/// lets it complete.
private final class GatedSender: ChatSending, @unchecked Sendable {
    let entered = AsyncGate()
    let release = AsyncGate()

    func sendMessage(_ text: String, model: String?) async throws {
        entered.signal()
        await release.wait()
    }

    func availableModels() async throws -> [ChatModel] { [] }
    func availableAgentPresets() async throws -> [AgentPreset] { [] }
}

/// A `ChatSending` stub whose `availableModels` parks until released and then returns a
/// configured list, so a test can interleave a rebind cycle with an in-flight picker load.
/// `entered` fires when the fetch begins; `release` lets it complete.
private final class GatedModelsSender: ChatSending, @unchecked Sendable {
    let entered = AsyncGate()
    let release = AsyncGate()
    private let models: [ChatModel]

    init(models: [ChatModel]) {
        self.models = models
    }

    func sendMessage(_ text: String, model: String?) async throws {}

    func availableModels() async throws -> [ChatModel] {
        entered.signal()
        await release.wait()
        return models
    }

    func availableAgentPresets() async throws -> [AgentPreset] { [] }
}

/// A main-actor-isolated tally for the `onSent` callback (which is `@MainActor`, not
/// `Sendable`), so the test reads firings without crossing an isolation boundary.
@MainActor
private final class CallCounter {
    var count = 0
}

/// A throwaway error to drive the failed-send path; `ComposerStore` maps any error to a
/// user-facing message, so its concrete type doesn't matter.
private struct StubSendError: Error {}
