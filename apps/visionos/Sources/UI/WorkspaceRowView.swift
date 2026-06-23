import SwiftUI

/// One workspace's row: a status dot, the name, and the status label. Shared by the
/// production list (`WorkspaceListView`, where selection and pending state surface a
/// trailing accessory) and the Project window's list (`ProjectWindowView`, which shows
/// neither). `isSelected`/`isPending` default off so the bare row needs no call-site noise.
struct WorkspaceRowView: View {
    let workspace: Workspace
    var isSelected: Bool = false
    var isPending: Bool = false

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(workspace.status.tint)
                .frame(width: 14, height: 14)
                .accessibilityLabel(workspace.status.label)
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).font(.headline)
                Text(workspace.status.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isPending {
                ProgressView()
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .frame(minHeight: 60)
        .opacity(isPending ? 0.6 : 1)
        .contentShape(Rectangle())
    }
}
