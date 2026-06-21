import Foundation
import Observation

/// Presentation-agnostic source of truth for the Prompt composer (PRD §7.2/§9): the
/// reviewable draft, the cloud model picker, the Host-gated agent-preset list, and the
/// explicit-send action. Renderer views observe it; they never own domain state, and
/// dictation/keyboard both write the same `draft` (co-equal inputs).
///
/// V1 sends through the **client-owned chat session** Watch polls (`chat.sendMessage`,
/// ADR-0010): the built-in chat agent on a chosen cloud model. Host agent presets are
/// surfaced for visibility but are not the active agent in V1 — directing them needs the
/// session discovery deferred to V2.
@MainActor
@Observable
final class ComposerStore {
    /// Drives the send button + error notice. A failed send keeps the draft so the user
    /// can retry without re-dictating.
    enum SendState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// The reviewable prompt — bound to both the keyboard field and dictation output, so
    /// the user always reviews/edits before an explicit send (never send-on-pause, §9).
    var draft: String = ""
    /// The selected cloud model id (`metadata.model`); nil lets the Host pick its default.
    var selectedModelID: String?

    private(set) var models: [ChatModel] = []
    /// Host-gated presets, empty when the Host is asleep/unreachable (PRD §7.2).
    private(set) var agentPresets: [AgentPreset] = []
    private(set) var sendState: SendState = .idle

    private var sender: ChatSending?
    /// Called after a prompt lands so the watch can re-poll immediately ("see the run").
    private var onSent: (@MainActor () -> Void)?
    /// The Workspace the bound sender serves, so re-binding the same Workspace keeps the
    /// in-progress draft while switching Workspaces clears it.
    private var boundWorkspaceID: String?

    /// Whether the draft is sendable: non-empty and not mid-flight. (Model/preset choices
    /// are optional — the Host has a default model and V1's agent is always the built-in.)
    var canSend: Bool {
        sendState != .sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bind the sender for `workspaceID`. Re-binding the same Workspace is a no-op (keeps
    /// the draft); binding a different Workspace resets the composer so one window never
    /// sends another's draft.
    func bind(sender: ChatSending, workspaceID: String, onSent: @escaping @MainActor () -> Void) {
        if boundWorkspaceID == workspaceID { return }
        self.sender = sender
        self.onSent = onSent
        boundWorkspaceID = workspaceID
        draft = ""
        selectedModelID = nil
        models = []
        agentPresets = []
        sendState = .idle
    }

    /// Load the pickers. The cloud model list is required-ish (it drives the default
    /// selection); the Host preset list is best-effort and stays empty when the Host is
    /// asleep — neither failure blocks composing or sending. The initial selection honors
    /// the user's `preferredModelID` setting when that model is offered, else the first.
    func loadPickers(preferredModelID: String? = nil) async {
        guard let sender else { return }
        let loadWorkspaceID = boundWorkspaceID
        if let fetched = try? await sender.availableModels() {
            guard boundWorkspaceID == loadWorkspaceID else { return }
            models = fetched
            if selectedModelID == nil {
                if let preferredModelID, fetched.contains(where: { $0.id == preferredModelID }) {
                    selectedModelID = preferredModelID
                } else {
                    selectedModelID = fetched.first?.id
                }
            }
        }
        let presets = (try? await sender.availableAgentPresets()) ?? []
        guard boundWorkspaceID == loadWorkspaceID else { return }
        agentPresets = presets
    }

    /// Send the current draft. Clears it on success and pings the watch to re-poll; on
    /// failure keeps the draft and surfaces a message so the user can retry.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await deliver(text, clearingDraft: true)
    }

    /// One-tap quick action (approve/reject/retry, PRD §9). The tap is itself the explicit
    /// send; it does not disturb a draft the user may be composing.
    func sendQuickAction(_ text: String) async {
        await deliver(text, clearingDraft: false)
    }

    private func deliver(_ text: String, clearingDraft: Bool) async {
        guard let sender, sendState != .sending else { return }
        let sendWorkspaceID = boundWorkspaceID
        let sentCallback = onSent
        sendState = .sending
        do {
            try await sender.sendMessage(text, model: selectedModelID)
            guard boundWorkspaceID == sendWorkspaceID else { return }
            if clearingDraft { draft = "" }
            sendState = .idle
            sentCallback?()
        } catch {
            guard boundWorkspaceID == sendWorkspaceID else { return }
            sendState = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AuthError.notAuthenticated:
            return "Not signed in."
        case AuthError.noActiveOrganization:
            return "No organization available."
        case let AuthError.badServerResponse(status) where status == 403:
            return "Sending needs a reachable Host on a paid plan."
        case let AuthError.badServerResponse(status):
            return "Host returned HTTP \(status)."
        default:
            return "Couldn't reach the Host. Try again."
        }
    }
}
