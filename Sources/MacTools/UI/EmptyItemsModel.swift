import AppKit
import Foundation

@MainActor
final class EmptyItemsModel: ObservableObject {
    @Published var rootURL: URL?
    @Published private(set) var report: EmptyItemsScanReport?
    @Published var selectedIDs = Set<String>()
    @Published var kindFilter: EmptyItemKind?
    @Published var searchText = ""
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published var showingReview = false
    @Published var banner: String?

    let isDemo: Bool
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private var pendingReviewItemsList: [EmptyCleanupItem] = []
    private var demoRoot: URL?

    init(isDemo: Bool = AppEnvironment.isDemo) {
        self.isDemo = isDemo
    }

    var allItems: [EmptyCleanupItem] {
        report?.items ?? []
    }

    var visibleItems: [EmptyCleanupItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            if let kindFilter, item.kind != kindFilter { return false }
            guard !query.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(query)
                || item.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedItems: [EmptyCleanupItem] {
        allItems.filter { selectedIDs.contains($0.id) }
    }

    var pendingReviewItems: [EmptyCleanupItem] {
        pendingReviewItemsList
    }

    var quickFolders: [(title: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized
        return [
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Home", home)
        ]
    }

    func prepareDemoIfNeeded() {
        guard isDemo, report == nil, !isScanning else { return }
        let root = URL(fileURLWithPath: "/private/tmp/MacToolsEmptyItemsDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeDemoFiles()
        demoRoot = root

        let emptyDir1 = root.appendingPathComponent("Old Export Folder", isDirectory: true)
        let emptyDir2 = root.appendingPathComponent("Archive/2024-Drafts", isDirectory: true)
        let brokenLink = root.appendingPathComponent("MissingShortcut")
        let missingTarget = root.appendingPathComponent("NonExistentFile.txt")

        try? FileManager.default.createDirectory(at: emptyDir1, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: emptyDir2, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: missingTarget)

        scan(folder: root)
    }

    func chooseFolder() {
        guard !isScanning, !isCleaning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Scan for Empty Folders & Broken Links"
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
                try EmptyItemsCleaner.scan(root: targetRoot)
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
            if let existing = report {
                report = EmptyItemsScanReport(
                    rootURL: existing.rootURL,
                    items: existing.items.filter { !removedIDs.contains($0.id) },
                    issues: existing.issues,
                    inspectedCount: existing.inspectedCount
                )
            }
            selectedIDs.subtract(removedIDs)
            banner = "Demo mode: simulated moving \(chosen.count) \(chosen.count == 1 ? "item" : "items") to Trash."
            return
        }

        isCleaning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                try EmptyItemsCleaner.moveToTrash(items: chosen, root: currentRoot)
            }.result

            self.isCleaning = false
            switch result {
            case .success(let outcome):
                let removedIDs = Set(outcome.trashed.map(\.id))
                if let existing = self.report {
                    self.report = EmptyItemsScanReport(
                        rootURL: existing.rootURL,
                        items: existing.items.filter { !removedIDs.contains($0.id) },
                        issues: existing.issues + outcome.issues,
                        inspectedCount: existing.inspectedCount
                    )
                }
                self.selectedIDs.subtract(removedIDs)
                self.banner = "Moved \(outcome.trashed.count) \(outcome.trashed.count == 1 ? "item" : "items") to Trash."
            case .failure(let err):
                self.banner = err.localizedDescription
            }
        }
    }

    func reveal(_ item: EmptyCleanupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url.deletingLastPathComponent()])
    }

    func removeDemoFiles() {
        guard let demoRoot,
              demoRoot.lastPathComponent.hasPrefix("MacToolsEmptyItemsDemo-"),
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
