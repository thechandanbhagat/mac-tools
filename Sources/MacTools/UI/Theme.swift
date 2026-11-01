import SwiftUI

/// Adaptive native surfaces keep file names and controls legible in both appearances.
enum Palette {
    static let accent = Color(nsColor: NSColor(name: "ToolAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.39, green: 0.79, blue: 0.69, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.40, blue: 0.33, alpha: 1)
    })
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
}

func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

func displayPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

extension CleanupCategory {
    var symbol: String {
        switch self {
        case .caches: "shippingbox"
        case .logs: "doc.text"
        case .downloads: "arrow.down.circle"
        case .largeFiles: "doc.zipper"
        }
    }
    var explanation: String {
        switch self {
        case .caches: "Temporary app files. Close their apps before cleaning."
        case .logs: "Diagnostic files you may no longer need."
        case .downloads: "Downloaded files. Keep anything you still use."
        case .largeFiles: "Files over 100 MB in Documents and Desktop."
        }
    }
    var location: String {
        switch self {
        case .caches: "~/Library/Caches"
        case .logs: "~/Library/Logs"
        case .downloads: "~/Downloads"
        case .largeFiles: "~/Documents · ~/Desktop"
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 20).padding(.vertical, 11)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Palette.canvas)
    }
}

/// One contextual entry point supports hover help, keyboard access, and click.
struct HelpTip: View {
    let text: String
    let label: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(label)
        .accessibilityHint(text)
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(18)
                .frame(width: 320, alignment: .leading)
        }
    }
}
