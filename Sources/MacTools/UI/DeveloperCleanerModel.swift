import AppKit
import Foundation

@MainActor
final class DeveloperCleanerModel: ObservableObject {
    typealias ScanWork = @Sendable (URL) throws -> DeveloperScanReport
    typealias CleanupWork = @Sendable ([DeveloperArtifact], URL) throws -> DeveloperCleanupOutcome

    @Published var rootURL: URL?
    @Published private(set) var report: DeveloperScanReport?
    @Published var selectedIDs = Set<String>()
    @Published var filterKind: DeveloperArtifactKind?
    @Published var searchText = ""
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var showingReview = false
    @Published var banner: String?

    let isDemo: Bool
    private let scanWork: ScanWork
    private let cleanupWork: CleanupWork
    private var scanTask: Task<Void, Never>?
    private var activeGeneration = 0
    private var pendingReviewArtifacts: [DeveloperArtifact] = []
    private var demoRoot: URL?

    init(
        isDemo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"),
        scanWork: @escaping ScanWork = { try DeveloperCleaner.scan(root: $0) },
        cleanupWork: @escaping CleanupWork = { try DeveloperCleaner.moveToTrash(artifacts: $0, root: $1) }
    ) {
        self.isDemo = isDemo
        self.scanWork = scanWork
        self.cleanupWork = cleanupWork
    }

    var artifacts: [DeveloperArtifact] {
        report?.artifacts ?? []
    }

    var issues: [DeveloperScanIssue] {
        report?.issues ?? []
    }

    var visibleArtifacts: [DeveloperArtifact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return artifacts.filter { item in
            let matchesKind = filterKind == nil || item.kind == filterKind
            guard matchesKind else { return false }
            guard !query.isEmpty else { return true }
            return item.projectName.localizedCaseInsensitiveContains(query)
                || item.kind.title.localizedCaseInsensitiveContains(query)
                || item.kind.rawValue.localizedCaseInsensitiveContains(query)
                || item.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedArtifacts: [DeveloperArtifact] {
        artifacts.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedArtifacts.reduce(0) { $0 + $1.byteCount }
    }

    var pendingReviewItems: [DeveloperArtifact] {
        pendingReviewArtifacts
    }

    var pendingReviewBytes: Int64 {
        pendingReviewArtifacts.reduce(0) { $0 + $1.byteCount }
    }

    var quickFolders: [(title: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        var result: [(String, URL)] = []
        for name in ["Projects", "Developer", "Code", "Workspace"] {
            let candidate = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                result.append((name, candidate))
            }
        }
        result.append(("Home", home))
        return result
    }

    public func prepareDemoIfNeeded() {
        guard isDemo, report == nil, !isScanning else { return }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacToolsDevCleanerDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeDemoFiles()
        demoRoot = root

        let webApp = root.appendingPathComponent("marketing-site/node_modules/.cache", isDirectory: true)
        let swiftApp = root.appendingPathComponent("mac-utility/.build/arm64-apple-macosx", isDirectory: true)
        let rustTool = root.appendingPathComponent("cli-engine/target/debug", isDirectory: true)
        let pyService = root.appendingPathComponent("ml-worker/.venv/lib", isDirectory: true)

        try? FileManager.default.createDirectory(at: webApp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: swiftApp, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: rustTool, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: pyService, withIntermediateDirectories: true)

        try? Data(repeating: 0x41, count: 520_000).write(to: webApp.appendingPathComponent("bundle.pack"))
        try? Data(repeating: 0x42, count: 380_000).write(to: swiftApp.appendingPathComponent("MacUtility.o"))
        try? Data(repeating: 0x43, count: 290_000).write(to: rustTool.appendingPathComponent("libengine.rlib"))
        try? Data(repeating: 0x44, count: 160_000).write(to: pyService.appendingPathComponent("site.pyc"))

        scan(folder: root)
    }

    public func chooseFolder() {
        guard !isScanning, !isCleaning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Projects Folder"
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            scan(folder: url)
        }
    }

    public func scan(folder: URL? = nil) {
        guard !isCleaning else { return }
        if let folder {
            rootURL = folder.standardized
        }
        guard let targetRoot = rootURL else {
            chooseFolder()
            return
        }

        scanTask?.cancel()
        activeGeneration += 1
        let generation = activeGeneration
        isScanning = true
        showingReview = false
        pendingReviewArtifacts = []
        banner = nil
        let work = scanWork

        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                try work(targetRoot)
            }.result

            guard generation == self.activeGeneration else { return }
            self.isScanning = false
            self.scanTask = nil

            switch result {
            case .success(let report):
                self.report = report
                self.selectedIDs = []
                if let filterKind = self.filterKind,
                   !report.artifacts.contains(where: { $0.kind == filterKind }) {
                    self.filterKind = nil
                }
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }
    }

    public func cancelScan() {
        activeGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    public func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    public func selectAllVisible() {
        for item in visibleArtifacts {
            selectedIDs.insert(item.id)
        }
    }

    public func clearSelection() {
        selectedIDs.removeAll()
    }

    public func presentReview() {
        let chosen = selectedArtifacts
        guard !chosen.isEmpty, !isScanning, !isCleaning else { return }
        pendingReviewArtifacts = chosen
        showingReview = true
    }

    public func cancelReview() {
        showingReview = false
        pendingReviewArtifacts = []
    }

    public func confirmTrash() {
        let chosen = pendingReviewArtifacts
        guard !chosen.isEmpty, let currentRoot = report?.rootURL ?? rootURL, !isCleaning else {
            cancelReview()
            return
        }
        showingReview = false
        pendingReviewArtifacts = []

        if isDemo {
            let removedIDs = Set(chosen.map(\.id))
            let reclaimed = chosen.reduce(Int64(0)) { $0 + $1.byteCount }
            if let existing = report {
                report = DeveloperScanReport(
                    rootURL: existing.rootURL,
                    artifacts: existing.artifacts.filter { !removedIDs.contains($0.id) },
                    issues: existing.issues,
                    inspectedCount: existing.inspectedCount
                )
            }
            selectedIDs.subtract(removedIDs)
            banner = "Demo mode: simulated moving \(chosen.count) build folder\(chosen.count == 1 ? "" : "s") (\(bytes(reclaimed))) to Trash."
            return
        }

        isCleaning = true
        let work = cleanupWork
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try work(chosen, currentRoot)
            }.result

            self.isCleaning = false
            switch result {
            case .success(let outcome):
                let removedIDs = Set(outcome.trashed.map(\.id))
                if let existing = self.report {
                    self.report = DeveloperScanReport(
                        rootURL: existing.rootURL,
                        artifacts: existing.artifacts.filter { !removedIDs.contains($0.id) },
                        issues: existing.issues + outcome.issues,
                        inspectedCount: existing.inspectedCount
                    )
                }
                self.selectedIDs.subtract(removedIDs)
                if outcome.issues.isEmpty {
                    self.banner = "Moved \(outcome.trashed.count) build folder\(outcome.trashed.count == 1 ? "" : "s") (\(bytes(outcome.reclaimedBytes))) to Trash."
                } else {
                    self.banner = "Moved \(outcome.trashed.count) of \(chosen.count) folders to Trash. \(outcome.issues.count) couldn’t be moved."
                }
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }
    }

    func reveal(_ artifact: DeveloperArtifact) {
        NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
    }

    public func removeDemoFiles() {
        guard let demoRoot,
              demoRoot.lastPathComponent.hasPrefix("MacToolsDevCleanerDemo-"),
              demoRoot.deletingLastPathComponent().path == "/private/tmp" else { return }
        try? FileManager.default.removeItem(at: demoRoot)
        self.demoRoot = nil
    }

    public func shutdown() {
        cancelScan()
        cancelReview()
        removeDemoFiles()
    }
}
