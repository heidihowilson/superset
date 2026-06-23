/// Drives only the empty-state UI for the cloud-backed stores (`WorkspaceStore`,
/// `SettingsModel`, `ChatSessionStore`). Cached/loaded content is always shown — a poll
/// that is in flight or has failed never blanks an existing list or transcript. `failed`
/// carries the user-facing copy for the empty-state message.
enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
