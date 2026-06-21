import Foundation

/// Outcome of one host-service-over-relay watch poll — the unit of the ADR-0007
/// stream/host-call resilience telemetry (connect/poll/drop/host-offline/latency).
/// The first successful `poll` of a session is effectively the connect.
enum HostCallOutcome: Sendable, Equatable {
    /// A poll succeeded; `latency` is the round-trip to the Host over the relay.
    case poll(latency: Duration)
    /// The Host was unreachable. `planGated` distinguishes a plan/subscription 403 from
    /// an asleep Host (PRD §6.3 — host-offline is a first-class state, not an error).
    case hostOffline(planGated: Bool)
    /// Any other failed poll (transport/decoding/server error).
    case drop(reason: String)
}

/// Sink for host-call/stream telemetry, injected into the watch poll loop so the Domain
/// layer records outcomes without owning the transport (PRD §6.2 — the core stays
/// presentation/transport-agnostic).
@MainActor
protocol HostCallRecording: AnyObject {
    func record(_ outcome: HostCallOutcome, workspaceID: String)
}
