import SwiftUI

/// Presentation mapping for `WorkspaceStatus`. Lives in the UI layer so the domain
/// enum stays free of SwiftUI — reinforcing the presentation-agnostic core (PRD §6.2).
extension WorkspaceStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .hostOnline: "Host online"
        case .hostAsleep: "Host offline (asleep)"
        case .planGated: "Host offline (plan-gated)"
        case .unknown: "Status pending"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .idle: .blue
        case .hostOnline: .green
        case .hostAsleep: .secondary
        case .planGated: .orange
        case .unknown: .secondary
        }
    }
}
