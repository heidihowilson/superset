import Foundation

/// A Host-configured agent preset (`settings.agentConfigs.list`, PRD §7.2). Unlike the
/// model picker, the preset picker is **Host-gated**: the list comes from the Host over
/// the relay, so it is empty when the Host is asleep or unreachable.
///
/// V1 directs the **built-in chat agent** through the client-owned session that Watch
/// polls (`chat.sendMessage`, ADR-0010). Launching a configured Host preset uses
/// `agents.run`, which mints its own server-side session the headset cannot discover yet
/// — that is V2 (ADR-0010). So in V1 these presets are surfaced for visibility (proving
/// the Host link) but are not selectable as the active agent; only the fields the menu
/// shows are decoded (PRD §12).
struct AgentPreset: Identifiable, Sendable, Equatable, Codable {
    /// The configured agent instance id.
    let id: String
    /// The preset slug (icon/behavior tag); free-form on the Host.
    let presetId: String
    /// Display label (e.g. "Claude Code").
    let label: String
}
