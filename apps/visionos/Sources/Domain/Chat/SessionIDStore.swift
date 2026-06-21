import Foundation

/// Durable `workspaceId → sessionId` map for client-owned chat sessions (ADR-0010).
/// V1 has no way to *discover* a session for a Workspace, so the client mints a
/// `sessionId` (UUID) per Workspace, persists it in `UserDefaults`, and reuses it
/// across launches for `getSnapshot` / `sendMessage`. The headset watches the session
/// it owns — cross-client discovery is V2.
struct SessionIDStore: Sendable {
    private let keyPrefix = "chat.session.v1."

    /// The persisted session id for a Workspace, minting and saving one on first use.
    /// Deterministic across launches: the same Workspace always resolves to the same id.
    func sessionID(for workspaceID: String) -> String {
        let key = keyPrefix + workspaceID
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        UserDefaults.standard.set(minted, forKey: key)
        return minted
    }
}
