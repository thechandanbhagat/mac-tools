import AppKit
import Combine
import SwiftUI

@MainActor
final class VaultQuickPasteController: NSObject, ObservableObject {
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var isPasting = false
    @Published private(set) var isTrusted = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var targetName: String?

    private var vault: KeyVaultModel?
    private var settings: AppSettings?
    private let shortcut = VaultGlobalShortcut()
    private var pasteService: (any VaultPasting)?
    private var target: VaultPasteTarget?
    private var panel: VaultQuickPastePanel?
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var subscriptions = Set<AnyCancellable>()
    private var pasteTask: Task<Void, Never>?
    private var isDismissing = false
    private var chooseOnReturnKeyUp = false

    func configure(vault: KeyVaultModel, settings: AppSettings) {
        guard self.vault == nil else { return }
        self.vault = vault
        self.settings = settings
        pasteService = SystemVaultPasteService(isDemo: vault.isDemo)
        refreshPermission()
        updateShortcut()
        settings.$quickPasteEnabled.dropFirst().sink { [weak self] enabled in
            self?.updateShortcut(enabled: enabled)
        }.store(in: &subscriptions)
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    func refreshPermission() { isTrusted = pasteService?.isTrusted ?? false }

    private func updateShortcut(enabled: Bool? = nil) {
        shortcutError = nil
        guard let settings else { return }
        // A preview must not take the installed app's global shortcut.
        guard enabled ?? settings.quickPasteEnabled, vault?.isDemo == false else {
            shortcut.unregister()
            dismiss()
            return
        }
        do { try shortcut.register { [weak self] in self?.show() } }
        catch { shortcutError = error.localizedDescription }
    }

    func show() {
        guard !isPasting, let vault else { return }
        if panel?.isVisible == true { dismiss(); return }
        refreshPermission()
        target = vault.isDemo ? nil : pasteService?.captureTarget()
        targetName = target?.appName
        query = ""
        selectedID = nil
        error = nil
        notice = nil
        vault.load(force: true)
        presentPanel()
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        chooseOnReturnKeyUp = false
        removeMonitors()
        panel?.orderOut(nil)
        isDismissing = false
    }

    func choose(_ entry: VaultEntry) {
        guard !isPasting, let vault, !vault.isBusy, vault.entries.contains(entry) else { return }
        selectedID = entry.id
        notice = nil
        guard !vault.isDemo else { notice = "Demo · Pasting disabled"; return }
        refreshPermission()
        guard isTrusted else {
            error = "Allow Mac Tools in Accessibility settings, then use the shortcut again. You can also copy this item."
            return
        }
        guard let target, let pasteService else {
            error = "Focus a text field, then press ⌃⌥V again. You can also copy this item."
            return
        }
        error = nil
        isPasting = true
        dismiss()
        pasteTask = Task { [weak self] in
            do {
                try await pasteService.paste(entry.content, to: target, isSensitive: entry.isSensitive)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.refreshPermission()
                self.presentPanel()
            }
            self?.isPasting = false
            self?.pasteTask = nil
        }
    }

    func copySelected() {
        guard let vault, !vault.isDemo, !isPasting,
              let entry = filteredEntries.first(where: { $0.id == selectedID }) ?? filteredEntries.first else { return }
        if vault.copy(entry) {
            error = nil
            notice = entry.isSensitive ? "Copied. Clears in 30 seconds." : "Copied. Paste with ⌘V."
        } else { error = "Couldn’t copy this item. Try again." }
    }

    func openAccessibilitySettings() {
        dismiss()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    var filteredEntries: [VaultEntry] {
        (vault?.entries ?? []).filter { $0.matches(query) }
    }

    var panelHeight: CGFloat {
        let count = filteredEntries.count
        let listHeight: CGFloat = count == 0 || vault?.isLoading == true ? 150 : CGFloat(min(count, 6)) * 52
        let needsExplanation = error != nil || (!isTrusted && vault?.isDemo == false)
        return min(450, max(220, 138 + listHeight + (needsExplanation ? 64 : 0)))
    }

    func resizePanel() {
        guard let panel, panel.isVisible else { return }
        let top = panel.frame.maxY
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        let bottom = min(max(top - panelHeight, screen.minY + 8), screen.maxY - panelHeight - 8)
        panel.setFrame(NSRect(x: panel.frame.minX, y: bottom, width: 380, height: panelHeight), display: true)
    }

    func moveSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else { selectedID = nil; return }
        let index = entries.firstIndex { $0.id == selectedID } ?? (offset > 0 ? -1 : entries.count)
        selectedID = entries[min(entries.count - 1, max(0, index + offset))].id
    }

    func chooseSelected() {
        if let entry = filteredEntries.first(where: { $0.id == selectedID }) ?? filteredEntries.first { choose(entry) }
    }

    func shutdown() {
        dismiss()
        shortcut.unregister()
        pasteTask?.cancel()
        pasteService?.shutdown()
        pasteTask = nil
        isPasting = false
        if let appActivationObserver { NotificationCenter.default.removeObserver(appActivationObserver) }
        appActivationObserver = nil
        subscriptions.removeAll()
        panel = nil
    }

    private func presentPanel() {
        guard let vault, let settings else { return }
        if panel == nil {
            let panel = VaultQuickPastePanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: panelHeight),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            panel.title = "Key Vault Quick Paste"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
            panel.onResignKey = { [weak self] in self?.dismiss() }
            panel.contentView = NSHostingView(rootView: VaultQuickPasteView(controller: self, vault: vault, settings: settings))
            self.panel = panel
        }
        guard let panel else { return }
        panel.setContentSize(NSSize(width: 380, height: panelHeight))
        let mouse = NSEvent.mouseLocation
        let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: min(max(mouse.x, frame.minX + 8), frame.maxX - size.width - 8),
                                     y: min(max(mouse.y - size.height, frame.minY + 8), frame.maxY - size.height - 8)))
        panel.appearance = settings.appearance == .system ? nil : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return false }
                guard event.window === panel else { self.dismiss(); return false }
                if event.type == .keyUp, [36, 76].contains(event.keyCode), self.chooseOnReturnKeyUp {
                    self.chooseOnReturnKeyUp = false
                    self.chooseSelected()
                    return true
                }
                guard event.type == .keyDown else { return false }
                switch event.keyCode {
                case 53: self.dismiss(); return true
                case 125: self.moveSelection(by: 1); return true
                case 126: self.moveSelection(by: -1); return true
                // Consume autorepeats while the panel still owns keyboard focus.
                case 36, 76: self.chooseOnReturnKeyUp = true; return true
                default: return false
                }
            }
            return consume ? nil : event
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        localMonitor = nil
        mouseMonitor = nil
        activationObserver = nil
    }
}

private final class VaultQuickPastePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); onResignKey?() }
}
