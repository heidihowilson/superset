import SwiftUI

/// The brief sign-in surface shown when no token is in the Keychain. Sign-in itself
/// is a system-browser pass (ADR-0005), not a custom credential form — these buttons
/// only choose the OAuth provider and hand off to `ASWebAuthenticationSession`.
struct SignInView: View {
    let controller: AuthController

    private var isAuthenticating: Bool {
        controller.status == .authenticating
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Superset")
                    .font(.largeTitle.weight(.semibold))
                Text("Sign in to open your workspaces in space.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                ForEach(AuthHandoff.Provider.allCases, id: \.self) { provider in
                    Button {
                        Task { await controller.signIn(provider: provider) }
                    } label: {
                        Text(label(for: provider))
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(isAuthenticating)
                }
            }

            if isAuthenticating {
                VStack(spacing: 12) {
                    ProgressView()
                    Button("Cancel") {
                        controller.cancelSignIn()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            } else if case let .failed(message) = controller.status {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(48)
        .glassBackgroundEffect()
    }

    private func label(for provider: AuthHandoff.Provider) -> String {
        switch provider {
        case .google: return "Continue with Google"
        case .github: return "Continue with GitHub"
        }
    }
}
