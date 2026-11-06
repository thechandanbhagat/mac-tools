import AppKit
import SwiftUI

/// Construct the main window only after an explicit foreground launch or menu action.
/// This also prevents window restoration from surfacing the app during login.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, ObservableObject {
    var onVisibilityChange: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(content: AnyView) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 790),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Mac Tools"
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentMinSize = NSSize(width: 1000, height: 720)
            let hostingView = NSHostingView(rootView: content)
            hostingView.frame = NSRect(x: 0, y: 0, width: 1120, height: 790)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChange?()
    }

    func windowWillClose(_ notification: Notification) {
        // Window-close notification precedes the final visibility change.
        Task { @MainActor [weak self] in self?.onVisibilityChange?() }
    }
}
