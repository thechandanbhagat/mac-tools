import SwiftUI

struct StorageMapTrashConfirmation: View {
    let request: StorageMapTrashRequest
    let isDemo: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "trash").font(.system(size: 25)).foregroundStyle(.secondary)
                Text("Move “\(request.name)” to Trash?")
                    .font(.system(size: 21, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(request.url.path)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(4).truncationMode(.middle).textSelection(.enabled).help(request.url.path)
                Text("\(bytes(request.byteCount)) on disk").font(.system(size: 12)).monospacedDigit()
            }
            if request.isDirectory {
                Text("The folder and all its contents, including hidden items, will move to Trash.")
                    .font(.system(size: 13))
            }
            Text("You can restore it from Trash in Finder.").font(.system(size: 13))
            if isDemo {
                Text("Demo · Moving files is disabled.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent).disabled(isDemo)
            }
        }
        .padding(26).frame(width: 470)
        .onExitCommand(perform: onCancel)
    }
}
