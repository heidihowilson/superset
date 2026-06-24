import XCTest
@testable import Superset

/// Coverage for the lifecycle invariants `SessionMetrics` owns (PRD §17): M1 fires once
/// with the right launch_kind, the foreground session opens/closes idempotently across
/// multi-window churn, and M-Host's `had_live_host` flag tracks whether a `.poll` outcome
/// was recorded during the session.
@MainActor
final class SessionMetricsLifecycleTests: XCTestCase {
    /// Records the events `Telemetry` fans out, in order. `Telemetry.capture` sends on a
    /// detached task, so assertions wait via `drain` rather than reading synchronously.
    private actor RecordingTransport: TelemetryTransport {
        private(set) var events: [TelemetryEvent] = []

        func send(_ event: TelemetryEvent, distinctID: String) async {
            events.append(event)
        }

        func names() -> [String] { events.map(\.name) }
    }

    private func context() -> DeviceContext {
        DeviceContext(distinctID: "install-1", properties: ["device_model": .string("RealityDevice14,1")])
    }

    /// Yield until `condition` holds or a bounded number of yields elapse, letting the
    /// detached send tasks run before we assert — without a flaky fixed sleep.
    private func drain(until condition: @escaping () async -> Bool) async {
        for _ in 0 ..< 1000 where !(await condition()) { await Task.yield() }
    }

    /// Yield a fixed number of times so any (unexpected) pending send would have landed,
    /// used to assert that a second call emitted *nothing* more.
    private func settle() async {
        for _ in 0 ..< 50 { await Task.yield() }
    }

    // MARK: - M1

    func testFirstMeaningfulViewEmitsM1OnceAsWarmWithoutSignIn() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.markFirstMeaningfulView()
        metrics.markFirstMeaningfulView() // later appearances are ignored

        await drain { await transport.events.count >= 1 }
        await settle()

        let events = await transport.events
        XCTAssertEqual(events.map(\.name), ["m1_time_to_first_view"], "M1 fires exactly once")
        XCTAssertEqual(events.first?.properties["launch_kind"], .string("warm"), "no sign-in observed → warm launch")
    }

    func testSignInRequiredBeforeFirstViewMarksM1Cold() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.noteSignInRequired()
        metrics.markFirstMeaningfulView()

        await drain { await transport.events.count >= 1 }

        let events = await transport.events
        XCTAssertEqual(events.map(\.name), ["m1_time_to_first_view"])
        XCTAssertEqual(events.first?.properties["launch_kind"], .string("cold"), "sign-in observed → cold launch")
    }

    func testNoteSignInRequiredAfterFirstViewIsIgnored() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.markFirstMeaningfulView() // M1 already recorded as warm
        metrics.noteSignInRequired() // too late to flip the launch kind
        metrics.markFirstMeaningfulView()

        await drain { await transport.events.count >= 1 }
        await settle()

        let events = await transport.events
        XCTAssertEqual(events.map(\.name), ["m1_time_to_first_view"], "no second M1 after the first view")
        XCTAssertEqual(events.first?.properties["launch_kind"], .string("warm"), "a late sign-in note does not flip M1 to cold")
    }

    // MARK: - M4 / M-Host

    func testSessionStartIsIdempotentAndEndEmitsM4AndMHostOnce() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.sessionDidStart()
        metrics.sessionDidStart() // multi-window activation churn — still one session
        metrics.sessionDidEnd()
        metrics.sessionDidEnd() // already closed — no-op

        await drain { await transport.events.count >= 2 }
        await settle()

        let names = await transport.names()
        XCTAssertEqual(Set(names), ["m4_session_length", "m_host_session"])
        XCTAssertEqual(names.count, 2, "one session open/close emits M4 and M-Host exactly once each")

        let events = await transport.events
        for event in events {
            XCTAssertEqual(event.properties["had_live_host"], .bool(false), "no poll recorded → session had no live host")
        }
    }

    func testRecordingPollFlipsHadLiveHostTrue() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.sessionDidStart()
        metrics.record(.poll(latency: .milliseconds(12)), workspaceID: "ws-1")
        metrics.sessionDidEnd()

        await drain { await transport.events.count >= 2 }

        let events = await transport.events
        for event in events {
            XCTAssertEqual(event.properties["had_live_host"], .bool(true), "a successful poll means the session reached a live host")
        }
    }

    func testOfflineAndDropOutcomesLeaveHadLiveHostFalse() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.sessionDidStart()
        metrics.record(.hostOffline(planGated: false, latency: .milliseconds(5)), workspaceID: "ws-1")
        metrics.record(.drop(reason: "decode", latency: .milliseconds(7)), workspaceID: "ws-1")
        metrics.sessionDidEnd()

        await drain { await transport.events.count >= 2 }

        let events = await transport.events
        for event in events {
            XCTAssertEqual(event.properties["had_live_host"], .bool(false), "offline/drop outcomes never reached a live host")
        }
    }

    func testNewSessionResetsHadLiveHostAfterAPriorLiveSession() async {
        let transport = RecordingTransport()
        let metrics = SessionMetrics(telemetry: Telemetry(transport: transport, context: context()))

        metrics.sessionDidStart()
        metrics.record(.poll(latency: .milliseconds(10)), workspaceID: "ws-1")
        metrics.sessionDidEnd()
        await drain { await transport.events.count >= 2 }

        metrics.sessionDidStart() // a fresh session must not inherit the prior live-host flag
        metrics.sessionDidEnd()
        await drain { await transport.events.count >= 4 }

        let events = await transport.events
        let mHost = events.filter { $0.name == "m_host_session" }
        XCTAssertEqual(mHost.count, 2)
        XCTAssertEqual(mHost.first?.properties["had_live_host"], .bool(true), "first session polled → live host")
        XCTAssertEqual(mHost.last?.properties["had_live_host"], .bool(false), "second session reset → no live host")
    }
}
