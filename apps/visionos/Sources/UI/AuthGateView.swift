import SwiftUI

/// Gates the app on a Keychain session token (M0a). Signed out → `SignInView`;
/// signed in → the existing `RootView` (the M0 renderer seam) flanked by a session
/// connectivity check (which exercises the bearer seams) and a Sign Out affordance.
/// The `loading` flash while the Keychain is read is intentionally minimal — a
/// progress view, not a redirect.
struct AuthGateView: View {
    @State private var auth = AuthController()

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
            RootView()
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
