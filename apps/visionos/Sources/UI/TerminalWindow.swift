import SwiftUI
import TerminalSurface

/// The Terminal window scene id. A plain `WindowGroup` (no domain value) — a spike
/// surface opened from the Debug window, not wired into the production rail.
enum TerminalScene {
    static let windowID = "terminal"
}

/// Debug spike host for the `TerminalSurface` package. Two modes behind a picker:
///
/// - **Loopback** (Phase 1): `LoopbackTerminalIO` self-echo, proving the surface renders and
///   that two coexist — no relay, no host.
/// - **Live** (Phase 2): provisions a real host PTY (`terminal.createSession`) and attaches a
///   `RelayTerminalIO` over the relay WebSocket for a chosen Workspace. This is the path the
///   human manual test drives against a live, signed-in host.
///
/// Each `TerminalSurfaceController` owns an independent libghostty app + surface + render
/// loop; the controller is attached in `.onAppear` and detached in `.onDisappear`, the
/// lifecycle the package documents (INTEGRATION.md §4). Behind Debug — NOT the production rail.
struct TerminalWindow: View {
    let auth: AuthController
    let store: WorkspaceStore

    private enum Mode: String, CaseIterable, Identifiable {
        case loopback = "Loopback"
        case live = "Live (relay)"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .loopback

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("terminal-mode-picker")

            Divider()

            switch mode {
            case .loopback:
                LoopbackTerminalPane()
            case .live:
                LiveTerminalPane(auth: auth, store: store)
            }
        }
    }
}

/// Phase-1 loopback echo: a `TerminalSurface` driven by `LoopbackTerminalIO`, plus a two-up
/// toggle that proves N>1 terminals coexist. Unchanged from the original spike.
private struct LoopbackTerminalPane: View {
    @State private var showsSecond = false

    @StateObject private var primary = TerminalSurfaceController(
        configuration: TerminalConfiguration(fontSize: 18, theme: .tokyoNight)
    )
    @StateObject private var secondary = TerminalSurfaceController(
        configuration: TerminalConfiguration(fontSize: 18, theme: .tokyoNight)
    )

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal spike — loopback echo")
                    .font(.headline)
                Spacer()
                Toggle("Two terminals", isOn: $showsSecond)
                    .toggleStyle(.button)
                    .accessibilityIdentifier("terminal-two-up-toggle")
            }
            .padding()

            Divider()

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
}

/// Phase-2 live pane: pick a Workspace with a Host, connect, and attach a `RelayTerminalIO`
/// to the surface. Provisioning + the WS open run on `RelayTerminalSessionProvider`; control
/// frames (`attached`/`title`/`exit`/`error`) drive the status line. Detaches on disappear so
/// the socket and PTY pump tear down with the window.
private struct LiveTerminalPane: View {
    let auth: AuthController
    let store: WorkspaceStore

    @StateObject private var controller = TerminalSurfaceController(
        configuration: TerminalConfiguration(fontSize: 18, theme: .tokyoNight)
    )
    @State private var model = LiveTerminalModel()
    @State private var selectedWorkspaceID: Workspace.ID?

    /// Only Workspaces with a Host can open a terminal (the relay routes by `host`).
    private var connectableWorkspaces: [Workspace] {
        store.workspaces.filter { $0.hostID != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            TerminalSurfaceView(controller: controller)
                .onDisappear {
                    controller.detach()
                    model.disconnect()
                }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Workspace", selection: $selectedWorkspaceID) {
                Text("Select a workspace…").tag(Workspace.ID?.none)
                ForEach(connectableWorkspaces) { workspace in
                    Text("\(workspace.projectName)/\(workspace.name)").tag(Workspace.ID?.some(workspace.id))
                }
            }
            .accessibilityIdentifier("terminal-workspace-picker")
            .disabled(model.phase == .connecting)

            Button(model.phase == .attached ? "Reconnect" : "Connect") {
                connect()
            }
            .disabled(selectedWorkspaceID == nil || model.phase == .connecting)
            .accessibilityIdentifier("terminal-connect-button")

            Spacer()

            Text(model.statusLine)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(model.phase == .failed ? .red : .secondary)
                .accessibilityIdentifier("terminal-status")
        }
        .padding()
    }

    private func connect() {
        guard
            let id = selectedWorkspaceID,
            let workspace = connectableWorkspaces.first(where: { $0.id == id })
        else { return }
        model.connect(auth: auth, workspace: workspace, controller: controller)
    }
}

/// Drives the live pane's connection lifecycle on the main actor: kicks off provisioning,
/// attaches the transport to the surface, seeds the initial PTY size from the grid, and folds
/// control frames + errors into a status line. Owns the in-flight `Task` so a reconnect or a
/// window close cancels it.
@MainActor
@Observable
final class LiveTerminalModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case attached
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var statusLine: String = "Idle"

    private var connectTask: Task<Void, Never>?
    private var connection: RelayTerminalSessionProvider.Connection?

    func connect(auth: AuthController, workspace: Workspace, controller: TerminalSurfaceController) {
        guard let provider = auth.makeTerminalSessionProvider(for: workspace) else {
            phase = .failed
            statusLine = "No host for this workspace"
            return
        }

        disconnect()
        phase = .connecting
        statusLine = "Connecting to \(workspace.name)…"
        controller.presentLocally("Connecting to \(workspace.name)…\r\n")

        // Capture `self` directly here (a stable reference from this @MainActor scope) rather
        // than through the connect task's own weak binding, so the @Sendable control handler
        // doesn't reach into the task's captured `self` var from concurrent code.
        let onControl: @Sendable (TerminalControlMessage) -> Void = { [weak self] control in
            Task { @MainActor in self?.handle(control) }
        }

        connectTask = Task { [weak self] in
            do {
                let connection = try await provider.connect(onControl: onControl)
                guard !Task.isCancelled else {
                    connection.io.close()
                    return
                }
                guard let self else {
                    connection.io.close()
                    return
                }
                self.connection = connection
                self.phase = .attached
                self.statusLine = "Attached (\(connection.terminalId))"
                controller.attach(connection.io)
                // Seed the PTY at the surface's current grid so the first frame is sized
                // right; libghostty re-emits resize on subsequent layout changes.
                let grid = controller.gridSize
                connection.io.resize(cols: UInt16(grid.cols), rows: UInt16(grid.rows))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed
                self.statusLine = "Failed: \(error.localizedDescription)"
                controller.presentLocally("Connection failed: \(error.localizedDescription)\r\n")
            }
        }
    }

    /// Fold an inbound control frame into the status line.
    private func handle(_ control: TerminalControlMessage) {
        switch control {
        case let .attached(terminalId):
            phase = .attached
            statusLine = "Attached (\(terminalId))"
        case let .title(title):
            if let title, !title.isEmpty { statusLine = title }
        case let .exit(exitCode, signal):
            phase = .idle
            statusLine = "Exited (code \(exitCode), signal \(signal))"
        case let .error(message):
            phase = .failed
            statusLine = "Error: \(message)"
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        connection?.io.close()
        connection = nil
        if phase == .attached || phase == .connecting {
            phase = .idle
            statusLine = "Disconnected"
        }
    }
}
