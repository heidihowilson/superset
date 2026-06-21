import SwiftUI

/// The Optic ID lock screen (ADR-0008). Covers signed-in content while the gate is
/// engaged — on launch, on foreground, or after a failed attempt — and offers a single
/// retry that re-runs the system Optic ID prompt. Purely a presentation of
/// `LockController.state`; the controller owns the credential side effects.
struct LockView: View {
    @Bindable var lock: LockController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "opticid")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)

            Text("Superset is locked")
                .font(.title2.weight(.semibold))

            Text("Verify with Optic ID to see your workspaces.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            switch lock.state {
            case .authenticating:
                ProgressView()
                    .padding(.top, 4)
            case let .failed(message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                unlockButton("Try Again")
            default:
                unlockButton("Unlock with Optic ID")
            }
        }
        .padding(40)
        .frame(maxWidth: 360)
        .glassBackgroundEffect()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlockButton(_ title: String) -> some View {
        Button(title, systemImage: "opticid") {
            Task { await lock.authenticate() }
        }
        .buttonStyle(.borderedProminent)
        .padding(.top, 4)
    }
}
