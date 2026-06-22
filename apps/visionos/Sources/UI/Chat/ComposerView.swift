import SwiftUI

/// The Prompt composer (PRD §7.2/§9): voice dictation and the virtual keyboard as
/// co-equal inputs into one reviewable draft, an explicit Send, quick-action chips, a
/// cloud model picker, and a Host-gated agent picker. Native chrome (ADR-0003); ≥60pt
/// targets and explicit button shapes per the visionOS interaction bar (§9).
///
/// Dictation streams into the same `draft` the keyboard edits, so the user always reviews
/// before sending (never send-on-pause). When recognition would run on Apple's servers
/// rather than on-device, a privacy notice is shown (§13).
struct ComposerView: View {
    let store: ComposerStore
    /// Whether the agent is blocked on a user approve/reject decision (the host's
    /// `pendingApproval`). The Approve/Reject/Retry chips show only then (PRD §9).
    let awaitingDecision: Bool
    @State private var dictation = DictationController()
    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            quickActions
            serverRecognitionNotice
            inputRow
            sendError
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .task {
            dictation.onTranscript = { store.draft = $0 }
            if appSettings.dictationEnabled, case .unknown = dictation.availability {
                await dictation.requestAuthorization()
            }
        }
        .onDisappear { dictation.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dictation.stop() }
        }
        // Honor the Settings dictation toggle live: turning it off stops any live
        // session and removes the mic; turning it on requests authorization once so
        // the mic comes up ready without reopening the composer.
        .onChange(of: appSettings.dictationEnabled) { _, enabled in
            if enabled {
                if case .unknown = dictation.availability {
                    Task { await dictation.requestAuthorization() }
                }
            } else {
                dictation.stop()
            }
        }
    }

    // MARK: Quick actions

    @ViewBuilder
    private var quickActions: some View {
        if awaitingDecision {
            HStack(spacing: 12) {
                quickActionChip("Approve", systemImage: "checkmark")
                quickActionChip("Reject", systemImage: "xmark")
                quickActionChip("Retry", systemImage: "arrow.clockwise")
                Spacer(minLength: 0)
            }
        }
    }

    private func quickActionChip(_ title: String, systemImage: String) -> some View {
        Button {
            Task { await store.sendQuickAction(title.lowercased()) }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(minHeight: 44)
        }
        .buttonBorderShape(.capsule)
        .disabled(store.sendState == .sending)
        .accessibilityHint("Sends \(title.lowercased()) as a reply")
    }

    // MARK: Input row

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 12) {
            micButton
            TextField("Message the agent…", text: Bindable(store).draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .frame(minHeight: 60)
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .submitLabel(.send)
                .accessibilityIdentifier(AccessibilityID.composerInput)
            modelPicker
            agentPicker
            sendButton
        }
    }

    @ViewBuilder
    private var micButton: some View {
        if appSettings.dictationEnabled {
            let listening = dictation.state == .listening
            Button {
                toggleDictation()
            } label: {
                Image(systemName: listening ? "mic.fill" : "mic")
                    .font(.title2)
                    .frame(width: 60, height: 60)
            }
            .buttonBorderShape(.circle)
            .tint(listening ? .red : nil)
            .disabled(!dictation.isReady && !listening)
            .accessibilityLabel(listening ? "Stop dictation" : "Start dictation")
            .accessibilityIdentifier(AccessibilityID.composerMicToggle)
            .help(micHelp)
        }
    }

    private var micHelp: String {
        switch dictation.availability {
        case .denied:
            return "Microphone or speech access is off. Enable it in Settings to dictate."
        case .unavailable:
            return "Dictation isn't available on this device. Use the keyboard."
        default:
            return "Dictate your prompt; review it, then send."
        }
    }

    private func toggleDictation() {
        if dictation.state == .listening {
            dictation.stop()
        } else {
            try? dictation.start()
        }
    }

    // MARK: Pickers

    private var modelPicker: some View {
        Menu {
            ForEach(modelsByProvider, id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models) { model in
                        Button {
                            store.selectedModelID = model.id
                        } label: {
                            if store.selectedModelID == model.id {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(selectedModelName, systemImage: "cpu")
                .frame(minHeight: 60)
                .padding(.horizontal, 12)
        }
        .buttonBorderShape(.capsule)
        .disabled(store.models.isEmpty)
        .accessibilityLabel("Model: \(selectedModelName)")
    }

    /// The agent picker is Host-gated discovery (PRD §7.2): V1 always drives the built-in
    /// chat agent through the client-owned session (ADR-0010), so that is the only
    /// selectable entry; the Host's configured presets are listed but disabled (directing
    /// them from the headset is V2). The list is empty when the Host is asleep.
    private var agentPicker: some View {
        Menu {
            Section("Agent") {
                Label("Superset", systemImage: "checkmark")
            }
            Section("Host agents") {
                if store.agentPresets.isEmpty {
                    Text("None — Host asleep")
                } else {
                    ForEach(store.agentPresets) { preset in
                        Button { } label: { Text(preset.label) }
                            .disabled(true)
                    }
                }
            }
        } label: {
            Label("Superset", systemImage: "sparkles")
                .frame(minHeight: 60)
                .padding(.horizontal, 12)
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Agent: Superset")
    }

    private var sendButton: some View {
        Button {
            Task { await store.send() }
        } label: {
            Group {
                if store.sendState == .sending {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.title2)
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonBorderShape(.circle)
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSend)
        .accessibilityLabel("Send")
    }

    // MARK: Notices

    @ViewBuilder
    private var serverRecognitionNotice: some View {
        if dictation.state == .listening, dictation.usesServerRecognition {
            Label(
                "Dictation is processed on Apple servers on this device, not on-device.",
                systemImage: "exclamationmark.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sendError: some View {
        if case let .failed(message) = store.sendState {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Helpers

    private var selectedModelName: String {
        store.models.first { $0.id == store.selectedModelID }?.name ?? "Model"
    }

    private struct ModelGroup { let provider: String; let models: [ChatModel] }

    /// Models grouped by provider, preserving the server's order within each group.
    private var modelsByProvider: [ModelGroup] {
        var order: [String] = []
        var byProvider: [String: [ChatModel]] = [:]
        for model in store.models {
            if byProvider[model.provider] == nil { order.append(model.provider) }
            byProvider[model.provider, default: []].append(model)
        }
        return order.map { ModelGroup(provider: $0, models: byProvider[$0] ?? []) }
    }
}
