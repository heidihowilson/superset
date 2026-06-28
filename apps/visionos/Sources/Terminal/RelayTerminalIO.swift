import Foundation
import TerminalSurface

/// The slice of `URLSessionWebSocketTask` the terminal transport drives, factored to a
/// protocol so `RelayTerminalIO` can be unit-tested against an in-memory stub (no live
/// socket). `URLSessionWebSocketTask` conforms as-is.
protocol TerminalWebSocketTask: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: TerminalWebSocketTask {}

/// `TerminalIO` over a relay WebSocket — the Phase-2 transport that replaces the loopback
/// echo. Binary frames from the host stream into `output` (rendered by the surface); the
/// terminal's keystrokes and grid resizes go out as `{"type":"input"|"resize"}` text frames;
/// inbound text control frames (`attached`/`title`/`exit`/`error`) are decoded and handed to
/// `onControl`. Mirrors the web's `TerminalConnection` minus reconnect (T6).
///
/// ### Concurrency
/// `send`/`resize` are invoked on libghostty's termio thread, **off** the main actor and
/// serialized (INTEGRATION.md §2). `URLSessionWebSocketTask.send` is `async`, so the calls
/// can't write the socket inline. Ordering is preserved by funnelling every outbound frame
/// through a single `AsyncStream` drained by one writer task: the stream keeps insertion
/// order and the writer `await`s each send before the next, so bytes stay in order without a
/// lock held across the network. State is guarded by a lock; the type is `@unchecked
/// Sendable` because `TerminalIO` must be `Sendable` and the surface holds it across actors.
final class RelayTerminalIO: TerminalIO, @unchecked Sendable {
    let output: AsyncStream<Data>

    private let task: TerminalWebSocketTask
    private let onControl: @Sendable (TerminalControlMessage) -> Void
    private let outboundContinuation: AsyncStream<String>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation

    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var started = false
    private var closed = false

    init(
        task: TerminalWebSocketTask,
        onControl: @escaping @Sendable (TerminalControlMessage) -> Void = { _ in }
    ) {
        self.task = task
        self.onControl = onControl

        var outputCont: AsyncStream<Data>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { outputCont = $0 }
        outputContinuation = outputCont

        var outboundCont: AsyncStream<String>.Continuation!
        let outbound = AsyncStream<String>(bufferingPolicy: .unbounded) { outboundCont = $0 }
        outboundContinuation = outboundCont

        // The single writer: drains queued frames in FIFO order, awaiting each send so the
        // socket sees them ordered. A send failure closes the transport (T6 adds reconnect).
        let task = self.task
        writeTask = Task { [weak self] in
            for await frame in outbound {
                do {
                    try await task.send(.string(frame))
                } catch {
                    self?.close()
                    return
                }
            }
        }
    }

    /// Resume the socket and start pumping inbound frames. Idempotent.
    func start() {
        let shouldStart: Bool = lock.withLock {
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        task.resume()
        let receive = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        lock.withLock { receiveTask = receive }
    }

    func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        outboundContinuation.yield(TerminalWireMessage.encodeInput(bytes))
    }

    func resize(cols: UInt16, rows: UInt16) {
        outboundContinuation.yield(TerminalWireMessage.encodeResize(cols: cols, rows: rows))
    }

    /// Tear down: cancel the socket and the pump tasks and finish `output` so the surface
    /// sees the transport close. Idempotent and safe from any thread.
    func close() {
        let shouldClose: Bool = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }

        task.cancel(with: .normalClosure, reason: nil)
        outboundContinuation.finish()
        outputContinuation.finish()
        let (receive, write) = lock.withLock { (receiveTask, writeTask) }
        receive?.cancel()
        write?.cancel()
    }

    /// Pump inbound frames until the socket closes or errors. Binary → `output`; text →
    /// decode as a control frame (ignored if unrecognized). Any receive error ends the loop
    /// and closes the transport.
    private func receiveLoop() async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                close()
                return
            }
            switch message {
            case let .data(data):
                outputContinuation.yield(data)
            case let .string(text):
                if let control = TerminalWireMessage.decodeControl(text) {
                    onControl(control)
                }
            @unknown default:
                break
            }
        }
    }

    deinit { close() }
}
