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

    /// The Workspace whose minted session is `sessionID`, or `nil` if none on this
    /// device owns it. Backs `superset://session/<id>` deep links: V1 has no
    /// cross-client session index, so a session resolves only to the Workspace that
    /// minted it here (ADR-0010). Scans the persisted `workspaceId → sessionId` map.
    func workspaceID(forSession sessionID: String) -> String? {
        let defaults = UserDefaults.standard
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(keyPrefix) {
            if value as? String == sessionID {
                return String(key.dropFirst(keyPrefix.count))
            }
        }
        return nil
    }
}
