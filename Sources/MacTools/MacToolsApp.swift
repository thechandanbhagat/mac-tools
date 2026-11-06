import SwiftUI
import AppKit
import Combine

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var mainWindow = MainWindowController()
    @StateObject private var model = CleanerModel()
    @StateObject private var mapModel = StorageMapModel()
    @StateObject private var largeFilesModel = LargeFilesModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var devCleanerModel = DeveloperCleanerModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var emptyItemsModel = EmptyItemsModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var uninstallerModel = AppUninstallerModel()
    @StateObject private var duplicateModel = DuplicateFinderModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var startupModel = StartupManagerModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var portsModel = PortInspectorModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var monitorModel = SystemMonitorModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var renamerModel = BatchRenamerModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var clipboardModel: ClipboardHistoryModel
    @StateObject private var vaultModel = KeyVaultModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var quickPaste = VaultQuickPasteController()
    @StateObject private var launchAtLogin = LaunchAtLoginModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var converterModel = FileConverterModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var metadataModel = MetadataScrubberModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var checksumModel = ChecksumVerifierModel(isDemo: AppEnvironment.isDemo)
    @State private var selectedTool: AppTool

    init() {
        let preferences = AppSettings()
        _settings = StateObject(wrappedValue: preferences)
        _clipboardModel = StateObject(wrappedValue: ClipboardHistoryModel(
            isDemo: AppEnvironment.isDemo,
            captureOnLaunch: preferences.captureClipboardOnLaunch,
            historyLimit: preferences.clipboardHistoryLimit
        ))
        _selectedTool = State(initialValue: AppEnvironment.initialTool(defaultTool: preferences.startupTool))
    }
    private var scanDisabled: Bool {
        switch selectedTool {
        case .cleaner: model.isBusy || model.enabledCategories.isEmpty
        case .storageMap: mapModel.isBusy
        case .largeFiles: largeFilesModel.isScanning || largeFilesModel.isCleaning
        case .devCleaner: devCleanerModel.isScanning || devCleanerModel.isCleaning
        case .emptyItems: emptyItemsModel.isScanning || emptyItemsModel.isCleaning
        case .uninstaller: uninstallerModel.isBusy
        case .duplicates: duplicateModel.isBusy
        case .startup: startupModel.isBusy
        case .ports: portsModel.isRefreshing
        case .monitor: monitorModel.isBusy
        case .renamer: renamerModel.isBusy
        case .clipboard, .settings: true
        case .keyVault: vaultModel.isBusy
        case .converter: converterModel.isBusy
        case .metadata: metadataModel.isBusy
        case .checksums: checksumModel.isComputing
        }
    }
    private var reviewDisabled: Bool {
        switch selectedTool {
        case .cleaner: model.selectedItems.isEmpty || model.isBusy
        case .largeFiles: largeFilesModel.selectedItems.isEmpty || largeFilesModel.isScanning || largeFilesModel.isCleaning
        case .devCleaner: devCleanerModel.selectedArtifacts.isEmpty || devCleanerModel.isScanning || devCleanerModel.isCleaning
        case .emptyItems: emptyItemsModel.selectedItems.isEmpty || emptyItemsModel.isScanning || emptyItemsModel.isCleaning
        case .uninstaller: !uninstallerModel.canReview
        case .duplicates: duplicateModel.isBusy || duplicateModel.selectedFiles.isEmpty || duplicateModel.pendingRequest != nil
        case .renamer: !renamerModel.canApply
        default: true
        }
    }

    var body: some Scene {
        let _ = configureApplication()
        MenuBarExtra(isInserted: Binding(
            get: { settings.showMenuBarItem },
            set: { isInserted in
                // macOS echoes the current value during scene updates.
                if settings.showMenuBarItem != isInserted { settings.showMenuBarItem = isInserted }
            }
        )) {
            MacToolsMenuContent(model: monitorModel, clipboardModel: clipboardModel,
                                showReadings: settings.showMonitorMenuBar, openMainWindow: showMainWindow)
        } label: {
            if settings.showMonitorMenuBar {
                Text(monitorModel.summaryTitle).accessibilityLabel("Mac Tools, \(monitorModel.summaryTitle)")
            } else {
                Image(systemName: "square.stack.3d.up").accessibilityLabel("Mac Tools")
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    showMainWindow(tool: .settings)
                }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Tools") {
                Button("Cleaner") { selectedTool = .cleaner }.keyboardShortcut("1", modifiers: .command)
                Button("Storage Map") { selectedTool = .storageMap }.keyboardShortcut("2", modifiers: .command)
                Button("Large & Old Files") { selectedTool = .largeFiles }.keyboardShortcut("3", modifiers: .command)
                Button("Developer Cleaner") { selectedTool = .devCleaner }.keyboardShortcut("4", modifiers: .command)
                Button("Duplicate Finder") { selectedTool = .duplicates }.keyboardShortcut("5", modifiers: .command)
                Button("Empty & Broken") { selectedTool = .emptyItems }
                Divider()
                Button("Batch Renamer") { selectedTool = .renamer }.keyboardShortcut("6", modifiers: .command)
                Button("File Converter") { selectedTool = .converter }.keyboardShortcut("7", modifiers: .command)
                Button("Metadata") { selectedTool = .metadata }
                Button("Checksums") { selectedTool = .checksums }.keyboardShortcut("8", modifiers: .command)
                Button("Clipboard History") { selectedTool = .clipboard }.keyboardShortcut("9", modifiers: .command)
                Button("Key Vault") { selectedTool = .keyVault }
                Button("Quick Paste…") { quickPaste.show() }
                Divider()
                Button("Uninstaller") { selectedTool = .uninstaller }
                Button("Startup Manager") { selectedTool = .startup }
                Button("Active Ports") { selectedTool = .ports }
                Button("System Monitor") { selectedTool = .monitor }
                Divider()
                Button("Refresh Selected Tool") {
                    switch selectedTool {
                    case .cleaner: model.startScan()
                    case .storageMap: mapModel.scan()
                    case .largeFiles: largeFilesModel.scan()
                    case .devCleaner: devCleanerModel.scan()
                    case .emptyItems: emptyItemsModel.scan()
                    case .uninstaller: uninstallerModel.refresh()
                    case .duplicates: duplicateModel.scan()
                    case .startup: startupModel.refresh()
                    case .ports: portsModel.refresh()
                    case .monitor: monitorModel.refresh()
                    case .renamer: renamerModel.refresh()
                    case .clipboard, .settings: break
                    case .keyVault: vaultModel.load(force: true)
                    case .converter: converterModel.refresh()
                    case .metadata: metadataModel.refresh()
                    case .checksums: checksumModel.recompute()
                    }
                }.keyboardShortcut("r", modifiers: .command).disabled(scanDisabled)
                Button("Review Selected Files") {
                    switch selectedTool {
                    case .cleaner: model.showReview = true
                    case .largeFiles: largeFilesModel.presentReview()
                    case .devCleaner: devCleanerModel.presentReview()
                    case .emptyItems: emptyItemsModel.presentReview()
                    case .uninstaller: uninstallerModel.review()
                    case .duplicates: duplicateModel.review()
                    case .renamer: renamerModel.review()
                    default: break
                    }
                }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(reviewDisabled)
            }
        }
    }

    private var mainContent: some View {
        MainWindowContent(settings: settings, selection: $selectedTool, onSelectionChange: updateMonitoring) {
            AppShellView(cleanerModel: model, mapModel: mapModel, largeFilesModel: largeFilesModel,
                     devCleanerModel: devCleanerModel, emptyItemsModel: emptyItemsModel,
                     uninstallerModel: uninstallerModel, duplicateModel: duplicateModel,
                     startupModel: startupModel, portsModel: portsModel, monitorModel: monitorModel,
                     renamerModel: renamerModel, clipboardModel: clipboardModel, vaultModel: vaultModel,
                     converterModel: converterModel, metadataModel: metadataModel,
                     checksumModel: checksumModel, settings: settings, quickPaste: quickPaste,
                     launchAtLogin: launchAtLogin, selection: $selectedTool)
        }
    }

    private func showMainWindow(tool: AppTool? = nil) {
        if let tool { selectedTool = tool }
        mainWindow.show(content: AnyView(mainContent))
    }

    private func configureApplication() {
        guard !appDelegate.isConfigured else { return }
        appDelegate.isConfigured = true
        appDelegate.shouldKeepRunning = { settings.showMenuBarItem || settings.quickPasteEnabled }
        appDelegate.isFinishingFileChange = { renamerModel.isApplying || vaultModel.isSaving }
        appDelegate.finishFileChange = {
            await renamerModel.finishPendingOperation()
            await vaultModel.finishPendingOperation()
        }
        appDelegate.onReopen = { showMainWindow() }
        vaultModel.onSensitiveContentsChange = { contents in clipboardModel.setSensitiveContents(contents) }
        clipboardModel.setSensitiveContents(vaultModel.entries.filter(\.isSensitive).map(\.content))
        mainWindow.onVisibilityChange = { updateMonitoring() }
        settings.$showMonitorMenuBar.combineLatest(settings.$showMenuBarItem)
            .dropFirst()
            .sink { _ in
                // Published values are delivered before assignment; read them on the next turn.
                Task { @MainActor in updateMonitoring() }
            }.store(in: &appDelegate.settingsSubscriptions)
        settings.$clipboardHistoryLimit.dropFirst()
            .sink { limit in clipboardModel.setHistoryLimit(limit) }
            .store(in: &appDelegate.settingsSubscriptions)
        appDelegate.onTermination = {
            quickPaste.shutdown()
            model.removeDemoFiles()
            mapModel.shutdown()
            largeFilesModel.shutdown()
            devCleanerModel.shutdown()
            emptyItemsModel.shutdown()
            uninstallerModel.shutdown()
            duplicateModel.shutdown()
            startupModel.shutdown()
            portsModel.shutdown()
            monitorModel.shutdown()
            renamerModel.shutdown()
            clipboardModel.shutdown()
            vaultModel.shutdown()
            converterModel.shutdown()
            metadataModel.shutdown()
            checksumModel.shutdown()
        }
        appDelegate.configureLaunch { inBackground in
            quickPaste.configure(vault: vaultModel, settings: settings)
            if inBackground {
                // A background launch must retain a visible route back into the app.
                settings.showMenuBarItem = true
            } else {
                showMainWindow()
            }
            updateMonitoring()
        }
    }

    private func updateMonitoring() {
        if (mainWindow.isVisible && selectedTool == .monitor) || (settings.showMenuBarItem && settings.showMonitorMenuBar) { monitorModel.start() }
        else { monitorModel.stop() }
    }
}

/// Observed properties must be evaluated inside the retained hosting tree.
private struct MainWindowContent<Content: View>: View {
    @ObservedObject var settings: AppSettings
    @Binding var selection: AppTool
    let onSelectionChange: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(minWidth: 1000, minHeight: 720)
            .tint(Palette.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            .onChange(of: selection) { _, _ in onSelectionChange() }
    }
}

private struct MacToolsMenuContent: View {
    @ObservedObject var model: SystemMonitorModel
    @ObservedObject var clipboardModel: ClipboardHistoryModel
    let showReadings: Bool
    let openMainWindow: (AppTool?) -> Void
    var body: some View {
        Button("Open Mac Tools") {
            openMainWindow(nil)
        }
        Button("Key Vault") { openTool(.keyVault) }
        Button("Clipboard History") { openTool(.clipboard) }
        Button("System Monitor") { openTool(.monitor) }
        Divider()
        if showReadings {
            SystemMonitorMenuView(model: model)
            Divider()
        }
        if !clipboardModel.history.entries.isEmpty {
            Text("Recent Clipboard")
            ForEach(clipboardModel.history.entries.prefix(5)) { entry in
                Button(entry.content.menuTitle) {
                    clipboardModel.copy(entry)
                }
            }
            Divider()
        }
        Button(clipboardModel.isMonitoring ? "Pause Clipboard Capture" : "Start Clipboard Capture") {
            if clipboardModel.isMonitoring { clipboardModel.pause() }
            else { clipboardModel.start() }
        }
        .disabled(clipboardModel.isDemo)
        Divider()
        Button("Settings…") { openTool(.settings) }
        Button("Quit Mac Tools") { NSApp.terminate(nil) }
    }

    private func openTool(_ tool: AppTool) {
        openMainWindow(tool)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var isConfigured = false
    var settingsSubscriptions = Set<AnyCancellable>()
    var onReopen: (() -> Void)?
    var onTermination: (() -> Void)?
    var shouldKeepRunning: (() -> Bool)?
    var isFinishingFileChange: (() -> Bool)?
    var finishFileChange: (() async -> Void)?
    private var waitingToTerminate = false
    private var launchInBackground: Bool?
    private var onLaunch: (@MainActor (Bool) -> Void)?

    func configureLaunch(_ action: @escaping @MainActor (Bool) -> Void) {
        onLaunch = action
        if let launchInBackground {
            Task { @MainActor in action(launchInBackground) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let inBackground = AppLaunchContext.requestedBackground()
            || AppLaunchContext.isLoginItemEvent(NSAppleEventManager.shared().currentAppleEvent)
        launchInBackground = inBackground
        if inBackground { NSApp.setActivationPolicy(.accessory) }
        onLaunch?(inBackground)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen?()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(shouldKeepRunning?() ?? false)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isFinishingFileChange?() == true else { return .terminateNow }
        if !waitingToTerminate {
            waitingToTerminate = true
            Task { @MainActor in
                await finishFileChange?()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { onTermination?() }
}
