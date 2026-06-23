import XCTest
@testable import Superset

/// Coverage for the bounded telemetry fan-out (#75). An asleep host means every captured
/// event would otherwise spawn a detached POST that times out, so an offline session piles
/// up unbounded in-flight requests. `Telemetry` caps concurrent sends and drops the excess.
final class TelemetryBoundsTests: XCTestCase {
    /// A transport whose `send` parks until released, standing in for an unreachable host
    /// where every POST hangs. It counts how many sends actually started.
    private actor StuckTransport: TelemetryTransport {
        private(set) var started = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func send(_ event: TelemetryEvent, distinctID: String) async {
            started += 1
            if released { return }
            await withCheckedContinuation { parked.append($0) }
        }

        func release() {
            released = true
            for continuation in parked { continuation.resume() }
            parked = []
        }
    }

    private func context() -> DeviceContext {
        DeviceContext(distinctID: "install-1", properties: ["device_model": .string("RealityDevice14,1")])
    }

    /// Poll until `condition` holds or a bounded number of yields elapse, letting the
    /// detached send tasks run before we assert — without a flaky fixed sleep.
    private func drain(until condition: @escaping () async -> Bool) async {
        for _ in 0 ..< 1000 where !(await condition()) { await Task.yield() }
    }

    func testInFlightSendsAreCappedWhileHostIsUnreachable() async {
        let transport = StuckTransport()
        let telemetry = Telemetry(transport: transport, context: context(), maxInFlight: 3)

        for i in 0 ..< 50 {
            telemetry.capture(TelemetryEvent(name: "event_\(i)"))
        }

        await drain { await transport.started >= 3 }
        let started = await transport.started
        XCTAssertEqual(started, 3, "an unreachable host can spawn at most maxInFlight concurrent sends, not one per event")

        await transport.release()
    }

    func testSlotsFreeUpAsSendsComplete() async {
        // With the transport draining immediately, sends complete and release their slot,
        // so a later capture is admitted rather than permanently starved by earlier ones.
        let transport = StuckTransport()
        await transport.release() // every send returns at once
        let telemetry = Telemetry(transport: transport, context: context(), maxInFlight: 2)

        // Fire one at a time, letting each send complete and free its slot before the next,
        // so admission depends on slots recycling rather than on a tight burst.
        for i in 0 ..< 10 {
            telemetry.capture(TelemetryEvent(name: "event_\(i)"))
            await drain { await transport.started >= i + 1 }
        }

        let started = await transport.started
        XCTAssertEqual(started, 10, "freed slots let later events through once earlier sends finish")
    }
}
