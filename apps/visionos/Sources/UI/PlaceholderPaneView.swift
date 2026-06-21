import SwiftUI

/// Renders a registered-but-deferred pane kind (PRD §8). Keeps synced layouts valid
/// without pretending the feature exists yet.
struct PlaceholderPaneView: View {
    let kind: PaneKind

    var body: some View {
        ContentUnavailableView(
            "\(kind.rawValue) pane",
            systemImage: "rectangle.dashed",
            description: Text("Registered placeholder — deferred to a later milestone.")
        )
    }
}
