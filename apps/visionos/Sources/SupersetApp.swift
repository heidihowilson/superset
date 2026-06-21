import SwiftUI

/// Native visionOS Superset client. V1 runs in the Shared Space (a plain
/// `WindowGroup`, no `ImmersiveSpace`); the system owns window placement and the
/// app passes only a `defaultSize` hint (PRD §7.1, PI-1).
@main
struct SupersetApp: App {
    var body: some Scene {
        WindowGroup {
            AuthGateView()
        }
        .defaultSize(width: 760, height: 820)
    }
}
