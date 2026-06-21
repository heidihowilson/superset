import SwiftUI

/// Gates the app on a Keychain session token (M0a). Signed out → `SignInView`;
/// signed in → the existing `RootView` (the M0 renderer seam) flanked by a session
/// connectivity check (which exercises the bearer seams) and a Sign Out affordance.
/// The `loading` flash while the Keychain is read is intentionally minimal — a
/// progress view, not a redirect.
struct AuthGateView: View {
    let auth: AuthController
    let store: WorkspaceStore

    var body: some View {
        content
            .onAppear { auth.restore() }
            .onOpenURL { auth.handleDeepLink($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch auth.status {
        case .loading:
            ProgressView()
        case .signedIn:
            RootView(store: store)
                .ornament(attachmentAnchor: .scene(.topLeading)) {
                    SessionStatusView(client: auth.makeAPIClient())
                }
                .ornament(attachmentAnchor: .scene(.topTrailing)) {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                        auth.signOut()
                        // Drop the previous account's cached Workspaces so the next
                        // sign-in never paints them (privacy + correctness).
                        store.reset()
                    }
                    .padding()
                    .glassBackgroundEffect()
                }
        case .signedOut, .authenticating, .failed:
            SignInView(controller: auth)
        }
    }
}
