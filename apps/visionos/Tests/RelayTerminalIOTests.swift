import XCTest
@testable import Superset

/// Drives `RelayTerminalIO` against an in-memory `TerminalWebSocketTask` stub (no live
/// socket): inbound binary frames must stream to `output`, inbound text control frames must
/// decode to `onControl`, and the terminal's keystrokes/resizes must leave as the expected
/// `input`/`resize` text frames in order. The transport is the seam libghostty drives off the
/// main actor, so a regression here is a silent break of the live terminal path.
final class RelayTerminalIOTests: XCTestCase {
    func testStartResumesTheSocket() async {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()
        await waitUntil { stub.didResume }
        XCTAssertTrue(stub.didResume)
        io.close()
    }

    func testInboundBinaryFramesStreamToOutput() async {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        var iterator = io.output.makeAsyncIterator()
        stub.deliver(.data(Data([0x68, 0x69]))) // "hi"
        let chunk = await iterator.next()
        XCTAssertEqual(chunk, Data([0x68, 0x69]))
        io.close()
    }

    func testInboundControlFramesDecodeToHandler() async {
        let stub = StubWebSocketTask()
        let received = ControlBox()
        let io = RelayTerminalIO(task: stub) { received.append($0) }
        io.start()

        stub.deliver(.string(#"{"type":"attached","terminalId":"t-1"}"#))
        await waitUntil { received.messages.contains(.attached(terminalId: "t-1")) }
        XCTAssertEqual(received.messages, [.attached(terminalId: "t-1")])
        io.close()
    }

    func testSendEncodesKeystrokesAsInputFrame() async throws {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        io.send(Data("echo hi\n".utf8))
        await waitUntil { !stub.sentFrames.isEmpty }

        let json = try object(XCTUnwrap(stub.sentFrames.first))
        XCTAssertEqual(json["type"] as? String, "input")
        XCTAssertEqual(json["data"] as? String, "echo hi\n")
        io.close()
    }

    func testResizeEncodesGridAsResizeFrame() async throws {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        io.resize(cols: 100, rows: 30)
        await waitUntil { !stub.sentFrames.isEmpty }

        let json = try object(XCTUnwrap(stub.sentFrames.first))
        XCTAssertEqual(json["type"] as? String, "resize")
        XCTAssertEqual(json["cols"] as? Int, 100)
        XCTAssertEqual(json["rows"] as? Int, 30)
        io.close()
    }

    func testOutboundFramesPreserveOrder() async {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        io.send(Data("a".utf8))
        io.resize(cols: 80, rows: 24)
        io.send(Data("b".utf8))
        await waitUntil { stub.sentFrames.count >= 3 }

        let types = stub.sentFrames.compactMap { frame -> String? in
            (try? object(frame))?["type"] as? String
        }
        XCTAssertEqual(types, ["input", "resize", "input"])
        io.close()
    }

    func testCloseCancelsTheSocketAndFinishesOutput() async {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        var iterator = io.output.makeAsyncIterator()
        io.close()
        // A finished stream returns nil from the iterator rather than hanging.
        let next = await iterator.next()
        XCTAssertNil(next)
        XCTAssertTrue(stub.didCancel)
    }

    func testSocketErrorFinishesOutput() async {
        let stub = StubWebSocketTask()
        let io = RelayTerminalIO(task: stub)
        io.start()

        var iterator = io.output.makeAsyncIterator()
        stub.deliverError(URLError(.networkConnectionLost))
        let next = await iterator.next()
        XCTAssertNil(next, "a receive error should finish the output stream")
        io.close()
    }

    // MARK: Helpers

    private func object(_ frame: String) throws -> [String: Any] {
        let data = try XCTUnwrap(frame.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Poll until `condition` holds or a generous timeout elapses — the outbound writer and
    /// inbound pump run on their own tasks, so the assertion can't read state synchronously.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @Sendable () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A `@Sendable`-safe sink for control messages observed off the pump task.
private final class ControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TerminalControlMessage] = []
    var messages: [TerminalControlMessage] { lock.withLock { stored } }
    func append(_ message: TerminalControlMessage) { lock.withLock { stored.append(message) } }
}

/// In-memory `TerminalWebSocketTask`: records outbound frames, lets a test push inbound
/// messages (or an error) into `receive()`, and tracks resume/cancel. `receive()` parks on a
/// continuation when the inbound queue is empty, matching a real socket awaiting bytes.
final class StubWebSocketTask: TerminalWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var resumed = false
    private var cancelled = false
    private var inbound: [URLSessionWebSocketTask.Message] = []
    private var pendingError: Error?
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    var sentFrames: [String] { lock.withLock { sent } }
    var didResume: Bool { lock.withLock { resumed } }
    var didCancel: Bool { lock.withLock { cancelled } }

    func resume() { lock.withLock { resumed = true } }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let frame: String
        switch message {
        case let .string(string): frame = string
        case let .data(data): frame = String(decoding: data, as: UTF8.self)
        @unknown default: frame = ""
        }
        lock.withLock { sent.append(frame) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbound.isEmpty {
                let message = inbound.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
            } else if let pendingError {
                self.pendingError = nil
                lock.unlock()
                continuation.resume(throwing: pendingError)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    /// Push an inbound frame into `receive()` (handing it to a parked waiter or queueing it).
    func deliver(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        if let continuation = waiter {
            waiter = nil
            lock.unlock()
            continuation.resume(returning: message)
        } else {
            inbound.append(message)
            lock.unlock()
        }
    }

    /// Fail the next (or pending) `receive()` — simulates the socket dropping.
    func deliverError(_ error: Error) {
        lock.lock()
        if let continuation = waiter {
            waiter = nil
            lock.unlock()
            continuation.resume(throwing: error)
        } else {
            pendingError = error
            lock.unlock()
        }
    }
}
