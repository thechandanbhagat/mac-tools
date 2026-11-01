import SwiftUI
import AppKit

@main
struct MacToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    @StateObject private var clipboardModel = ClipboardHistoryModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var converterModel = FileConverterModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var metadataModel = MetadataScrubberModel(isDemo: AppEnvironment.isDemo)
    @StateObject private var checksumModel = ChecksumVerifierModel(isDemo: AppEnvironment.isDemo)
    @State private var selectedTool = AppEnvironment.initialTool
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("showSystemMonitorMenuBar") private var showMonitorMenuBar = false

    private var colorScheme: ColorScheme? {
        appearance == "light" ? .light : appearance == "dark" ? .dark : nil
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
        case .clipboard: true
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
        Window("Mac Tools", id: "main") {
            AppShellView(cleanerModel: model, mapModel: mapModel, largeFilesModel: largeFilesModel,
                         devCleanerModel: devCleanerModel, emptyItemsModel: emptyItemsModel,
                         uninstallerModel: uninstallerModel, duplicateModel: duplicateModel,
                         startupModel: startupModel, portsModel: portsModel, monitorModel: monitorModel,
                         renamerModel: renamerModel, clipboardModel: clipboardModel,
                         converterModel: converterModel, metadataModel: metadataModel,
                         checksumModel: checksumModel, selection: $selectedTool)
                .frame(minWidth: 1000, minHeight: 720)
                .tint(Palette.accent)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    appDelegate.isFinishingFileChange = { renamerModel.isApplying }
                    appDelegate.finishFileChange = { await renamerModel.finishPendingOperation() }
                    appDelegate.onTermination = {
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
                        converterModel.shutdown()
                        metadataModel.shutdown()
                        checksumModel.shutdown()
                    }
                    updateMonitoring()
                }
                .onChange(of: selectedTool) { _, _ in updateMonitoring() }
                .onChange(of: showMonitorMenuBar) { _, _ in updateMonitoring() }
        }
        .defaultSize(width: 1120, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
                    case .clipboard: break
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
        Settings { SettingsView().tint(Palette.accent).preferredColorScheme(colorScheme) }
        MenuBarExtra(isInserted: $showMonitorMenuBar) {
            MonitorMenuContent(model: monitorModel, clipboardModel: clipboardModel, selection: $selectedTool)
        } label: {
            Text(monitorModel.summaryTitle)
        }
    }

    private func updateMonitoring() {
        if selectedTool == .monitor || showMonitorMenuBar { monitorModel.start() }
        else { monitorModel.stop() }
    }
}

private struct MonitorMenuContent: View {
    @ObservedObject var model: SystemMonitorModel
    @ObservedObject var clipboardModel: ClipboardHistoryModel
    @Binding var selection: AppTool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SystemMonitorMenuView(model: model)
        Divider()
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
        Button("Open Cleaner") { openTool(.cleaner) }
        Button("Open Storage Map") { openTool(.storageMap) }
        Button("Open Active Ports") { openTool(.ports) }
        Button("Open Mac Tools") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Mac Tools") { NSApp.terminate(nil) }
    }

    private func openTool(_ tool: AppTool) {
        selection = tool
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTermination: (() -> Void)?
    var isFinishingFileChange: (() -> Bool)?
    var finishFileChange: (() async -> Void)?
    private var waitingToTerminate = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showSystemMonitorMenuBar")
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
