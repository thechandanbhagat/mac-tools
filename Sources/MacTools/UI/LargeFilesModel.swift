import AppKit
import Foundation

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published var rootURL: URL?
    @Published private(set) var report: LargeFileScanReport?
    @Published var selectedIDs = Set<String>()
    @Published var threshold: LargeFileThreshold = .mb10
    @Published var ageFilter: StaleFileAgeFilter = .any
    @Published var kindFilter: LargeFileKind?
    @Published var searchText = ""
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var showingReview = false
    @Published var banner: String?

    let isDemo: Bool
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private var pendingReviewItemsList: [LargeFileItem] = []
    private var demoRoot: URL?

    init(isDemo: Bool = AppEnvironment.isDemo) {
        self.isDemo = isDemo
    }

    var allItems: [LargeFileItem] {
        report?.items ?? []
    }

    var visibleItems: [LargeFileItem] {
        let now = Date()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            guard item.byteCount >= threshold.rawValue else { return false }
            if let kindFilter, item.kind != kindFilter { return false }
            if let minAge = ageFilter.minimumAgeSeconds {
                guard now.timeIntervalSince(item.modifiedDate) >= minAge else { return false }
            }
            guard !query.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(query)
                || item.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedItems: [LargeFileItem] {
        allItems.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.byteCount }
    }

    var pendingReviewItems: [LargeFileItem] {
        pendingReviewItemsList
    }

    var pendingReviewBytes: Int64 {
        pendingReviewItemsList.reduce(0) { $0 + $1.byteCount }
    }

    var quickFolders: [(title: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized
        return [
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Movies", home.appendingPathComponent("Movies")),
            ("Home", home)
        ]
    }

    func prepareDemoIfNeeded() {
        guard isDemo, report == nil, !isScanning else { return }
        let root = URL(fileURLWithPath: "/private/tmp/MacToolsLargeFilesDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeDemoFiles()
        demoRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("macOS-SDK-Backup.dmg")
        let video = root.appendingPathComponent("ScreenRecording-2025.mov")
        let dataset = root.appendingPathComponent("training-export.parquet")

        try? Data(repeating: 0x31, count: 14_000_000).write(to: archive)
        try? Data(repeating: 0x32, count: 12_000_000).write(to: video)
        try? Data(repeating: 0x33, count: 11_000_000).write(to: dataset)

        let oldDate = Date().addingTimeInterval(-220 * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: archive.path)
        try? FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: video.path)

        scan(folder: root)
    }

    func chooseFolder() {
        guard !isScanning, !isCleaning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Scan for Large Files"
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            scan(folder: url)
        }
    }

    func scan(folder: URL? = nil) {
        guard !isCleaning else { return }
        if let folder {
            rootURL = folder.standardized
        }
        guard let targetRoot = rootURL else {
            chooseFolder()
            return
        }

        scanTask?.cancel()
        generation += 1
        let activeGen = generation
        isScanning = true
        showingReview = false
        pendingReviewItemsList = []
        banner = nil

        scanTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                try LargeFilesFinder.scan(root: targetRoot)
            }.result

            guard activeGen == self.generation else { return }
            self.isScanning = false
            self.scanTask = nil

            switch result {
            case .success(let report):
                self.report = report
                self.selectedIDs = []
            case .failure(let err) where err is CancellationError:
                break
            case .failure(let err):
                self.banner = err.localizedDescription
            }
        }
    }

    func cancelScan() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectAllVisible() {
        for item in visibleItems {
            selectedIDs.insert(item.id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func presentReview() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isScanning, !isCleaning else { return }
        pendingReviewItemsList = chosen
        showingReview = true
    }

    func cancelReview() {
        showingReview = false
        pendingReviewItemsList = []
    }

    func confirmTrash() {
        let chosen = pendingReviewItemsList
        guard !chosen.isEmpty, let currentRoot = report?.rootURL ?? rootURL, !isCleaning else {
            cancelReview()
            return
        }
        showingReview = false
        pendingReviewItemsList = []

        if isDemo {
            let removedIDs = Set(chosen.map(\.id))
            let reclaimed = chosen.reduce(Int64(0)) { $0 + $1.byteCount }
            if let existing = report {
                report = LargeFileScanReport(
                    rootURL: existing.rootURL,
                    items: existing.items.filter { !removedIDs.contains($0.id) },
                    issues: existing.issues,
                    inspectedCount: existing.inspectedCount
                )
            }
            selectedIDs.subtract(removedIDs)
            banner = "Demo mode: simulated moving \(chosen.count) \(chosen.count == 1 ? "file" : "files") (\(bytes(reclaimed))) to Trash."
            return
        }

        isCleaning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try LargeFilesFinder.moveToTrash(items: chosen, root: currentRoot)
            }.result

            self.isCleaning = false
            switch result {
            case .success(let outcome):
                let removedIDs = Set(outcome.trashed.map(\.id))
                if let existing = self.report {
                    self.report = LargeFileScanReport(
                        rootURL: existing.rootURL,
                        items: existing.items.filter { !removedIDs.contains($0.id) },
                        issues: existing.issues + outcome.issues,
                        inspectedCount: existing.inspectedCount
                    )
                }
                self.selectedIDs.subtract(removedIDs)
                self.banner = "Moved \(outcome.trashed.count) \(outcome.trashed.count == 1 ? "file" : "files") (\(bytes(outcome.reclaimedBytes))) to Trash."
            case .failure(let err):
                self.banner = err.localizedDescription
            }
        }
    }

    func reveal(_ item: LargeFileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func removeDemoFiles() {
        guard let demoRoot,
              demoRoot.lastPathComponent.hasPrefix("MacToolsLargeFilesDemo-"),
              demoRoot.deletingLastPathComponent().path == "/private/tmp" else { return }
        try? FileManager.default.removeItem(at: demoRoot)
        self.demoRoot = nil
    }

    func shutdown() {
        cancelScan()
        cancelReview()
        removeDemoFiles()
    }
}
