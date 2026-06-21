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
            // Any landing in a signed-out state — an explicit Sign Out, or a launch
            // where `restore()` finds the token expired/missing — must drop the
            // previous account's cached Workspaces. The store loads its durable cache
            // at app init, before a session is known, so without this the next sign-in
            // would paint the prior account's rows until the first poll (privacy +
            // correctness). Keying on `.signedOut` makes this the single owner.
            .onChange(of: auth.status) { _, status in
                if status == .signedOut { store.reset() }
            }
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
                    }
                    .padding()
                    .glassBackgroundEffect()
                }
        case .signedOut, .authenticating, .failed:
            SignInView(controller: auth)
        }
    }
}
