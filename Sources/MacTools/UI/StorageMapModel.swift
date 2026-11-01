import AppKit
import SwiftUI

@MainActor
final class StorageMapModel: ObservableObject {
    enum Phase { case ready, scanning, results }
    typealias ScanOperation = @Sendable (
        StorageMapConfiguration, @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> StorageMapResult
    typealias TrashOperation = @Sendable (StorageMapTrashRequest) async throws -> Void

    @Published var phase: Phase = .ready
    @Published private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published private var includesHidden = true
    var includeHidden: Bool {
        get { includesHidden }
        set {
            guard !isFileActionBusy, newValue != includesHidden else { return }
            includesHidden = newValue
            guard hasLocation else { return }
            result = nil
            scannedAt = nil
            startScan()
        }
    }
    @Published private(set) var result: StorageMapResult?
    // Navigation belongs to the chosen location, independent of a scan's nodes.
    // Ancestor nodes supply breadcrumb names only; their totals are never merged
    // with a new subtree scan, whose hard-link attribution may differ.
    @Published private(set) var breadcrumbs: [StorageMapNode] = []
    @Published private(set) var progressCount = 0
    @Published private(set) var progressPath = "Preparing map…"
    @Published private(set) var scannedAt: Date?
    @Published var error: String?
    @Published private(set) var errorTitle = "Unable to scan this folder"
    @Published var showIssues = false
    @Published private(set) var notice: String?
    @Published private(set) var pendingTrash: StorageMapTrashRequest?
    @Published private(set) var isPreparingTrash = false
    @Published private(set) var isTrashing = false

    let isDemo: Bool
    private let scanOperation: ScanOperation
    private let trashOperation: TrashOperation
    private var task: Task<Void, Never>?
    private var trashTask: Task<Void, Never>?
    private var trashGeneration = UUID()
    private var generation = UUID()
    private var demoRoot: URL?

    init(
        isDemo: Bool = AppEnvironment.isDemo,
        scanOperation: @escaping ScanOperation = { configuration, progress in
            try await StorageMapScanner().scan(configuration: configuration, progress: progress)
        },
        trashOperation: @escaping TrashOperation = { request in
            try await StorageMapTrash().moveToTrash(request: request)
        }
    ) {
        self.isDemo = isDemo
        self.scanOperation = scanOperation
        self.trashOperation = trashOperation
    }

    var isScanning: Bool { phase == .scanning }
    var isFileActionBusy: Bool { isPreparingTrash || isTrashing }
    var isBusy: Bool { isScanning || isFileActionBusy }
    var hasLocation: Bool { !breadcrumbs.isEmpty }
    var navigationIDs: [String] { breadcrumbs.map(\.id) }
    var currentURL: URL { breadcrumbs.last?.url ?? rootURL }
    var currentNode: StorageMapNode? {
        guard let result else { return nil }
        return result.nodes[result.rootID]
    }
    var children: [StorageMapNode] {
        (currentNode?.childIDs ?? []).compactMap { result?.nodes[$0] }
    }
    var currentTotal: Int64 { currentNode?.byteCount ?? 0 }

    func setRoot(_ url: URL) {
        guard !isBusy, !isDemo, url.isFileURL else { return }
        cancelTrash()
        rootURL = url.standardized
        phase = .ready
        result = nil
        breadcrumbs = []
        scannedAt = nil
        error = nil
        notice = nil
        showIssues = false
    }

    func chooseFolder() {
        guard !isBusy, !isDemo else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to map"
        panel.prompt = "Choose folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentURL
        if panel.runModal() == .OK, let url = panel.url {
            setRoot(url)
            scan()
        }
    }

    func scan() {
        guard !isBusy else { return }
        do {
            if isDemo, !hasLocation { rootURL = try prepareDemo() }
        } catch {
            self.error = "The sample files couldn’t be prepared. \(error.localizedDescription)"
            return
        }
        if !hasLocation {
            breadcrumbs = [StorageMapNode(
                id: rootURL.path, url: rootURL,
                name: rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent,
                isDirectory: true, isPackage: false, byteCount: 0, fileCount: 0,
                childIDs: [], isPartial: false
            )]
        }
        startScan()
    }

    private func startScan() {
        cancelTrash()
        task?.cancel()
        let configuration = StorageMapConfiguration(root: currentURL, includeHidden: includeHidden)
        let operation = scanOperation
        let scanID = UUID()
        generation = scanID
        phase = .scanning
        progressCount = 0
        progressPath = currentURL.path
        notice = nil
        error = nil
        errorTitle = "Unable to scan this folder"
        showIssues = false
        task = Task { [weak self] in
            do {
                let result = try await operation(configuration) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == scanID, self.isScanning else { return }
                        self.progressCount = progress.inspectedCount
                        self.progressPath = progress.currentPath
                    }
                }
                guard let self, self.generation == scanID, !Task.isCancelled else { return }
                self.result = result
                if let root = result.nodes[result.rootID], !self.breadcrumbs.isEmpty {
                    self.breadcrumbs[self.breadcrumbs.count - 1] = root
                }
                self.scannedAt = Date()
                self.phase = .results
                self.task = nil
            } catch is CancellationError {
                guard let self, self.generation == scanID else { return }
                self.finishCancelledScan()
            } catch {
                guard let self, self.generation == scanID else { return }
                self.phase = self.result == nil ? .ready : .results
                self.error = "This folder couldn’t be mapped. \(error.localizedDescription)"
                self.task = nil
            }
        }
    }

    func cancel() {
        guard isScanning else { return }
        generation = UUID()
        task?.cancel()
        finishCancelledScan()
    }

    private func finishCancelledScan() {
        phase = result == nil ? .ready : .results
        notice = "Scan cancelled."
        task = nil
    }

    func navigate(to node: StorageMapNode) {
        guard !isFileActionBusy else { return }
        if let index = breadcrumbs.firstIndex(where: { $0.id == node.id }) {
            guard index < breadcrumbs.count - 1 else { return }
            enter(Array(breadcrumbs.prefix(index + 1)))
        } else if let child = children.first(where: { $0.id == node.id }), child.isDirectory, !child.isPackage {
            enter(breadcrumbs + [child])
        }
    }

    func goBack() {
        guard !isFileActionBusy, breadcrumbs.count > 1 else { return }
        enter(Array(breadcrumbs.dropLast()))
    }

    func goToRoot() {
        guard !isFileActionBusy, breadcrumbs.count > 1, let root = breadcrumbs.first else { return }
        enter([root])
    }

    private func enter(_ trail: [StorageMapNode]) {
        breadcrumbs = trail
        result = nil
        scannedAt = nil
        startScan()
    }

    func reveal(_ node: StorageMapNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func canTrash(_ node: StorageMapNode) -> Bool {
        guard !isBusy, pendingTrash == nil,
              let current = children.first(where: { $0.id == node.id }) else { return false }
        return !current.isPackage && current.snapshot != nil
    }

    func requestTrash(_ node: StorageMapNode) {
        guard canTrash(node), let result,
              let current = children.first(where: { $0.id == node.id }) else { return }
        let actionID = UUID()
        trashGeneration = actionID
        isPreparingTrash = true
        error = nil
        notice = nil
        trashTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try StorageMapTrash.prepare(node: current, in: result)
                }
                let request = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, self.trashGeneration == actionID, !Task.isCancelled else { return }
                self.isPreparingTrash = false
                self.pendingTrash = request
                self.trashTask = nil
            } catch {
                guard let self, self.trashGeneration == actionID else { return }
                self.isPreparingTrash = false
                self.trashTask = nil
                self.errorTitle = "Unable to move item to Trash"
                self.error = error.localizedDescription
            }
        }
    }

    func cancelTrash() {
        guard !isTrashing else { return }
        trashGeneration = UUID()
        trashTask?.cancel()
        trashTask = nil
        isPreparingTrash = false
        pendingTrash = nil
    }

    func confirmTrash() {
        guard let request = pendingTrash, !isBusy, !isDemo else { return }
        pendingTrash = nil
        isTrashing = true
        let actionID = UUID()
        trashGeneration = actionID
        let operation = trashOperation
        trashTask = Task { [weak self] in
            do {
                try await operation(request)
                guard let self, self.trashGeneration == actionID else { return }
                self.isTrashing = false
                self.trashTask = nil
                self.result = nil
                self.scannedAt = nil
                self.startScan()
                self.notice = "Moved “\(request.name)” to Trash."
            } catch {
                guard let self, self.trashGeneration == actionID else { return }
                self.isTrashing = false
                self.trashTask = nil
                self.errorTitle = "Unable to move item to Trash"
                self.error = error.localizedDescription
            }
        }
    }

    func shutdown() {
        generation = UUID()
        trashGeneration = UUID()
        task?.cancel()
        trashTask?.cancel()
        task = nil
        guard let root = demoRoot,
              root.lastPathComponent.hasPrefix("MacTools-MapDemo-"),
              root.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Reproducible samples keep UI verification separate from personal folders.
    private func prepareDemo() throws -> URL {
        if let demoRoot { return demoRoot }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MacTools-MapDemo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        demoRoot = root
        let examples: [(String, Int)] = [
            ("Projects/Website/Preview.mov", 3_000_000),
            ("Projects/Website/Assets.zip", 1_200_000),
            ("Projects/Notes/Research.pdf", 600_000),
            ("Downloads/Design resources.zip", 2_300_000),
            ("Downloads/Installer.dmg", 1_000_000),
            ("Pictures/Weekend/Photo 1.jpg", 1_300_000),
            ("Pictures/Weekend/Photo 2.jpg", 1_100_000),
            ("Documents/Presentation.pdf", 900_000),
            ("Documents/Meeting notes.txt", 48_000),
            (".cache/Thumbnails.dat", 1_700_000),
            ("Example.app/Contents/Resources/Example.dat", 750_000),
            ("Read me.txt", 12_000)
        ]
        for (relative, size) in examples {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: size).write(to: file)
        }
        return root
    }
}
