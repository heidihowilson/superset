import SwiftUI
import CoreImage.CIFilterBuiltins

/// First-run onboarding — the lightweight, skippable, replayable **5-beat** tour
/// (PRD §7.2 / §16.3, FR-ONB). The beats teach the genuinely-new spatial HMI in order:
/// (1) gaze+pinch, (2) where the switcher/palette lives, (3) what "Host offline" means,
/// (4) open your first Workspace, (5) window-close vs pane-close.
///
/// Beat 4 is the one acceptance hinge: a **No-Host org** can't "open a first Workspace"
/// because there's nothing to open, so once the list has loaded and reports zero Hosts it
/// becomes the **"connect a Host"** terminal state (a scannable link to bring a Host
/// online) instead. The beat resolves reactively off the shared store, so an org whose
/// poll lands a Host mid-tour flips back to the open-a-Workspace beat.
struct OnboardingView: View {
    @Bindable var store: WorkspaceStore
    let onboarding: OnboardingStore

    @State private var index = 0

    private static let beatCount = 5

    var body: some View {
        VStack(spacing: 32) {
            header
            currentBeat
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(index)
            footer
        }
        .padding(40)
        .frame(minWidth: 460, minHeight: 520)
        .animation(.easeInOut(duration: 0.2), value: index)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            ForEach(0..<Self.beatCount, id: \.self) { dot in
                Capsule()
                    .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: dot == index ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: index)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(Self.beatCount)")
    }

    private var footer: some View {
        HStack {
            Button("Skip") { onboarding.complete() }
                .buttonStyle(.borderless)

            Spacer()

            if index > 0 {
                Button("Back") { index -= 1 }
                    .buttonBorderShape(.capsule)
            }

            if index < Self.beatCount - 1 {
                Button("Next") { index += 1 }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            } else {
                Button("Get Started") { onboarding.complete() }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .frame(minHeight: 60)
    }

    // MARK: Beats

    @ViewBuilder
    private var currentBeat: some View {
        switch index {
        case 0:
            BeatPage(
                symbol: "hand.tap",
                title: "Look, then pinch",
                message: "Look at any control to highlight it, then lightly pinch your thumb and index finger to select it. Rest your hands in your lap — there's nothing to reach out and touch."
            )
        case 1:
            BeatPage(
                symbol: "sidebar.leading",
                title: "Find your way around",
                message: "Your Workspace switcher lives on the leading edge of this window, with the main controls along the bottom edge. These ornaments stay put as you move — that's home base. With a hardware keyboard, ⌘K jumps straight to it."
            )
        case 2:
            BeatPage(
                symbol: "bolt.horizontal",
                title: "When the Host is offline",
                message: "Your Workspaces live on a Host — a Mac or remote machine running Superset. This list is always here, but watching an agent, sending a prompt, or creating a Workspace needs the Host awake. \"Host offline\" means that machine is asleep or unreachable; wake it and those actions light back up."
            )
        case 3:
            if isNoHostOrg {
                ConnectHostBeat()
            } else {
                BeatPage(
                    symbol: "rectangle.stack",
                    title: "Open your first Workspace",
                    message: "Pick any Workspace from the list to open it in its own window. Each one gets its own space — arrange them around you however you like."
                )
            }
        default:
            BeatPage(
                symbol: "macwindow",
                title: "Windows and panes",
                message: "⌘W closes the window you're looking at. Closing a single pane inside a Workspace is separate — it tidies that pane without closing the whole window."
            )
        }
    }

    /// True only once the list has actually loaded and reports no Hosts — an org with a
    /// genuinely empty Host roster (PRD §7.2 no-Host terminal state). While the first poll
    /// is still in flight the beat stays on "open a Workspace" (the optimistic default)
    /// rather than flashing the connect-a-Host state on cached/loading emptiness.
    private var isNoHostOrg: Bool {
        store.loadState == .loaded && store.hosts.isEmpty
    }
}

/// A single teaching beat: a large glanceable symbol, a title, and a short body. Targets
/// the headset's glance-first comfort profile (PRD §9) — minimal text, high contrast.
private struct BeatPage: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: symbol)
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}

/// The No-Host terminal state for beat 4 (PRD §7.2): an org with no Host can't open a
/// first Workspace, so it gets a "connect a Host" prompt with a scannable code and link
/// to bring one online. A Host is connected by running Superset on a Mac/remote machine
/// (host-service lives in the desktop app, not the web app), so the link points at the
/// product site rather than a web settings page that can't add a Host.
private struct ConnectHostBeat: View {
    /// Scanned on a phone to continue setup off-headset; also tappable as a link.
    private static let connectURL = URL(string: "https://superset.sh")!

    @State private var qr: Image?

    var body: some View {
        VStack(spacing: 20) {
            Text("Connect a Host")
                .font(.largeTitle.weight(.semibold))
            Text("You don't have a Host yet, so there's nothing to open. Run Superset on your Mac or a remote machine to bring a Host online — your Workspaces show up here once it's connected.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            qrCode

            Link(destination: Self.connectURL) {
                Label("superset.sh", systemImage: "arrow.up.right.square")
            }
            .font(.title3)
            .frame(minHeight: 60)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connect a Host. Run Superset on your Mac or a remote machine, then scan the code or visit superset.sh to get started.")
        .task {
            if qr == nil { qr = Self.makeQR(for: Self.connectURL.absoluteString) }
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let qr {
            qr
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 160, height: 160)
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("QR code linking to superset.sh")
        } else {
            // The QR generator never fails for a short ASCII URL, but degrade to the link
            // alone rather than reserve dead space if CoreImage is unavailable.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Render `string` to a crisp QR `Image` via CoreImage. The 1x output is a few points
    /// across, so callers scale it up with nearest-neighbor interpolation (`.none`) to keep
    /// the modules hard-edged.
    private static func makeQR(for string: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}

#Preview("Has Host") {
    OnboardingView(store: .sample(), onboarding: OnboardingStore(defaults: .standard))
}
