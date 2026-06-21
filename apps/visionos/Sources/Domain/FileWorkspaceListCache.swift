import Foundation

/// Caches the last Workspace-list snapshot to a JSON file in the caches directory so
/// a cold start paints the previous list instantly, before the first poll returns
/// (PRD §7.2 "cached for instant paint"). Best-effort: any read/write failure is
/// swallowed — a missing cache just means an empty first paint, never a crash.
struct FileWorkspaceListCache: WorkspaceListCaching {
    private let fileURL: URL

    init(fileName: String = "workspace-list.json") {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(fileName)
    }

    func load() -> WorkspaceListSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WorkspaceListSnapshot.self, from: data)
    }

    func save(_ snapshot: WorkspaceListSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
