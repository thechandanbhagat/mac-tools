import SwiftUI

/// Preview bundles can opt in so native tooling reopening them stays on samples.
enum AppEnvironment {
    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "MacToolsDemoMode") as? Bool == true
    }
    static var initialTool: AppTool {
        let flags: [(String, AppTool)] = [
            ("--duplicates", .duplicates),
            ("--dev-cleaner", .devCleaner),
            ("--large-files", .largeFiles),
            ("--empty-items", .emptyItems),
            ("--checksums", .checksums),
            ("--metadata", .metadata),
            ("--ports", .ports),
            ("--startup", .startup),
            ("--monitor", .monitor),
            ("--renamer", .renamer),
            ("--clipboard", .clipboard),
            ("--converter", .converter)
        ]
        if let entry = flags.first(where: { ProcessInfo.processInfo.arguments.contains($0.0) }) { return entry.1 }
        if ProcessInfo.processInfo.arguments.contains("--uninstaller") { return .uninstaller }
        if ProcessInfo.processInfo.arguments.contains("--storage-map") { return .storageMap }
        return (Bundle.main.object(forInfoDictionaryKey: "MacToolsInitialTool") as? String)
            .flatMap(AppTool.init(rawValue:)) ?? .cleaner
    }
}

enum AppToolSection: String, CaseIterable, Identifiable {
    case storage = "Storage"
    case files = "Files"
    case system = "System"

    var id: String { rawValue }

    var tools: [AppTool] {
        switch self {
        case .storage: [.cleaner, .storageMap, .largeFiles, .devCleaner, .duplicates, .emptyItems]
        case .files: [.renamer, .converter, .metadata, .checksums, .clipboard]
        case .system: [.uninstaller, .startup, .ports, .monitor]
        }
    }
}

enum AppTool: String, CaseIterable, Identifiable {
    case cleaner, storageMap, largeFiles, devCleaner, duplicates, emptyItems, renamer, converter, metadata, checksums, clipboard, uninstaller, startup, ports, monitor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleaner: "Cleaner"
        case .storageMap: "Storage Map"
        case .largeFiles: "Large & Old Files"
        case .devCleaner: "Developer Cleaner"
        case .duplicates: "Duplicate Finder"
        case .emptyItems: "Empty & Broken"
        case .renamer: "Batch Renamer"
        case .converter: "File Converter"
        case .metadata: "Metadata"
        case .checksums: "Checksums"
        case .clipboard: "Clipboard History"
        case .uninstaller: "Uninstaller"
        case .startup: "Startup Manager"
        case .ports: "Active Ports"
        case .monitor: "System Monitor"
        }
    }

    var symbol: String {
        switch self {
        case .cleaner: "internaldrive"
        case .storageMap: "square.grid.2x2"
        case .largeFiles: "doc.zipper"
        case .devCleaner: "hammer"
        case .duplicates: "doc.on.doc"
        case .emptyItems: "folder.badge.minus"
        case .renamer: "character.cursor.ibeam"
        case .converter: "arrow.triangle.2.circlepath"
        case .metadata: "eye.slash"
        case .checksums: "checkmark.shield"
        case .clipboard: "clipboard"
        case .uninstaller: "app.badge"
        case .startup: "power"
        case .ports: "network.badge.shield.half.filled"
        case .monitor: "waveform.path.ecg"
        }
    }
}

struct AppShellView: View {
    @ObservedObject var cleanerModel: CleanerModel
    @ObservedObject var mapModel: StorageMapModel
    @ObservedObject var largeFilesModel: LargeFilesModel
    @ObservedObject var devCleanerModel: DeveloperCleanerModel
    @ObservedObject var emptyItemsModel: EmptyItemsModel
    @ObservedObject var uninstallerModel: AppUninstallerModel
    @ObservedObject var duplicateModel: DuplicateFinderModel
    @ObservedObject var startupModel: StartupManagerModel
    @ObservedObject var portsModel: PortInspectorModel
    @ObservedObject var monitorModel: SystemMonitorModel
    @ObservedObject var renamerModel: BatchRenamerModel
    @ObservedObject var clipboardModel: ClipboardHistoryModel
    @ObservedObject var converterModel: FileConverterModel
    @ObservedObject var metadataModel: MetadataScrubberModel
    @ObservedObject var checksumModel: ChecksumVerifierModel
    @Binding var selection: AppTool
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch selection {
                case .cleaner:
                    CleanerView(model: cleanerModel, onHandoffFile: handoffFile)
                case .storageMap:
                    StorageMapView(model: mapModel, onHandoffFolder: handoffFolder, onHandoffFile: handoffFile)
                case .largeFiles:
                    LargeFilesView(model: largeFilesModel, onHandoffFile: handoffFile)
                case .devCleaner:
                    DeveloperCleanerView(model: devCleanerModel, onHandoffFolder: handoffFolder)
                case .emptyItems:
                    EmptyItemsView(model: emptyItemsModel)
                case .uninstaller:
                    AppUninstallerView(model: uninstallerModel)
                case .duplicates:
                    DuplicateFinderView(model: duplicateModel, onHandoffFile: handoffFile)
                case .startup:
                    StartupManagerView(model: startupModel)
                case .ports:
                    PortInspectorView(model: portsModel)
                case .monitor:
                    SystemMonitorView(model: monitorModel)
                case .renamer:
                    BatchRenamerView(model: renamerModel)
                case .clipboard:
                    ClipboardHistoryView(model: clipboardModel)
                case .converter:
                    FileConverterView(model: converterModel)
                case .metadata:
                    MetadataScrubberView(model: metadataModel)
                case .checksums:
                    ChecksumVerifierView(model: checksumModel)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(Palette.accent)
                Text("Mac Tools").font(.system(size: 18, weight: .semibold))
            }.padding(.top, 44).padding(.bottom, 22).padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(AppToolSection.allCases) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)
                            ForEach(section.tools) { tool in
                                sidebarButton(for: tool)
                            }
                        }
                    }
                }.padding(.horizontal, 10)
            }.scrollIndicators(.hidden)

            Spacer()
            Divider().padding(.horizontal, 18)
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.buttonStyle(.plain).padding(10).help("Open Mac Tools settings")
        }
        .frame(width: 214)
        .background(Palette.canvas)
    }

    private func sidebarButton(for tool: AppTool) -> some View {
        Button { selection = tool } label: {
            HStack(spacing: 8) {
                Label(tool.title, systemImage: tool.symbol)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isBusy(tool) {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 13, weight: selection == tool ? .semibold : .regular))
            .foregroundStyle(selection == tool ? Palette.accent : .primary)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(selection == tool ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tool ? [.isSelected] : [])
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls, onto: tool)
        }
    }

    private func handoffFolder(_ folder: URL, to tool: AppTool) {
        selection = tool
        switch tool {
        case .storageMap:
            mapModel.setRoot(folder)
            mapModel.scan()
        case .largeFiles:
            largeFilesModel.scan(folder: folder)
        case .devCleaner:
            devCleanerModel.scan(folder: folder)
        case .duplicates:
            duplicateModel.setRoot(folder)
        case .emptyItems:
            emptyItemsModel.scan(folder: folder)
        default:
            break
        }
    }

    private func handoffFile(_ file: URL, to tool: AppTool) {
        selection = tool
        switch tool {
        case .checksums:
            checksumModel.addFiles([file])
        case .metadata:
            metadataModel.addFiles([file])
        case .renamer:
            renamerModel.addFiles([file])
        case .converter:
            converterModel.addFiles([file])
        default:
            break
        }
    }

    private func handleDrop(_ urls: [URL], onto tool: AppTool) -> Bool {
        guard let first = urls.first else { return false }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        guard exists else { return false }

        if isDir.boolValue {
            switch tool {
            case .storageMap, .largeFiles, .devCleaner, .duplicates, .emptyItems:
                handoffFolder(first, to: tool)
                return true
            default:
                return false
            }
        } else {
            let files = urls.filter { url in
                var dir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
            }
            guard !files.isEmpty else { return false }
            switch tool {
            case .renamer:
                selection = .renamer
                renamerModel.addFiles(files)
                return true
            case .converter:
                selection = .converter
                converterModel.addFiles(files)
                return true
            case .metadata:
                selection = .metadata
                metadataModel.addFiles(files)
                return true
            case .checksums:
                selection = .checksums
                checksumModel.addFiles(files)
                return true
            default:
                return false
            }
        }
    }

    private func isBusy(_ tool: AppTool) -> Bool {
        switch tool {
        case .cleaner: cleanerModel.isBusy
        case .storageMap: mapModel.isBusy
        case .largeFiles: largeFilesModel.isScanning || largeFilesModel.isCleaning
        case .devCleaner: devCleanerModel.isScanning || devCleanerModel.isCleaning
        case .emptyItems: emptyItemsModel.isScanning || emptyItemsModel.isCleaning
        case .uninstaller: uninstallerModel.isBusy
        case .duplicates: duplicateModel.isBusy
        case .startup: startupModel.isBusy
        case .ports: portsModel.isRefreshing
        case .monitor: false
        case .renamer: renamerModel.isBusy
        case .clipboard: false
        case .converter: converterModel.isBusy
        case .metadata: metadataModel.isBusy
        case .checksums: checksumModel.isComputing
        }
    }
}
