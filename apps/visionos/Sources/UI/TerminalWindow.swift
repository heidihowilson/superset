import SwiftUI
import TerminalSurface

/// The Terminal window scene id. A plain `WindowGroup` (no domain value) — a spike
/// surface opened from the Debug window, not wired into the production rail.
enum TerminalScene {
    static let windowID = "terminal"
}

/// Phase-1 spike host for the `TerminalSurface` package. Embeds the libghostty-backed
/// terminal surface and drives it with `LoopbackTerminalIO` (a self-echo transport) so
/// keystrokes appear immediately — no SSH, no relay, no PTY. Proves the surface renders,
/// takes input, and that two coexist (the two-up variant) inside the Superset app.
///
/// Each `TerminalSurfaceController` owns an independent libghostty app + surface + render
/// loop; the controller is attached in `.onAppear` and detached in `.onDisappear`, the
/// lifecycle the package documents (INTEGRATION.md §4).
struct TerminalWindow: View {
    /// Toggles the two-up split that proves N>1 terminals coexist.
    @State private var showsSecond = false

    @StateObject private var primary = TerminalSurfaceController(
        configuration: TerminalConfiguration(fontSize: 18, theme: .tokyoNight)
    )
    @StateObject private var secondary = TerminalSurfaceController(
        configuration: TerminalConfiguration(fontSize: 18, theme: .tokyoNight)
    )

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            terminals
        }
    }

    private var controls: some View {
        HStack {
            Text("Terminal spike — loopback echo")
                .font(.headline)
            Spacer()
            Toggle("Two terminals", isOn: $showsSecond)
                .toggleStyle(.button)
                .accessibilityIdentifier("terminal-two-up-toggle")
        }
        .padding()
    }

    @ViewBuilder
    private var terminals: some View {
        HStack(spacing: 0) {
            TerminalSurfaceView(controller: primary)
                .onAppear { primary.attach(LoopbackTerminalIO(banner: "echo A — type here\r\n")) }
                .onDisappear { primary.detach() }

            if showsSecond {
                Divider()
                TerminalSurfaceView(controller: secondary)
                    .onAppear { secondary.attach(LoopbackTerminalIO(banner: "echo B — type here\r\n")) }
                    .onDisappear { secondary.detach() }
            }
        }
    }
}
