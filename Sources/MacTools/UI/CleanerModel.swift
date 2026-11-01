import SwiftUI
import AppKit

struct DiskSnapshot {
    let total: Int64
    let available: Int64
    let name: String
    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
    static func read() -> DiskSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        return DiskSnapshot(total: Int64(total), available: Int64(available), name: values.volumeName ?? "Macintosh HD")
    }
}

@MainActor
final class CleanerModel: ObservableObject {
    enum Phase { case ready, scanning, results, cleaning }
    @Published var phase: Phase = .ready
    @Published var disk = DiskSnapshot.read()
    @Published var enabledCategories = Set(CleanupCategory.allCases)
    @Published var items: [StorageItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var filter: CleanupCategory?
    @Published var query = ""
    @Published var sortLargestFirst = true
    @Published var progressCount = 0
    @Published var progressPath = "Preparing scan…"
    @Published var issues: [String] = []
    @Published var showIssues = false
    @Published var showReview = false
    @Published var notice: String?
    @Published var error: String?
    @Published var lastScanned: Date?
    let isDemo = AppEnvironment.isDemo
    private var task: Task<Void, Never>?
    private var scanConfiguration: ScanConfiguration?
    private var demoRoot: URL?

    var isBusy: Bool { phase == .scanning || phase == .cleaning }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    var selectedItems: [StorageItem] { items.filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.byteCount } }
    var filteredItems: [StorageItem] {
        let result = items.filter { item in
            (filter == nil || item.category == filter) &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.url.path.localizedCaseInsensitiveContains(query))
        }
        return result.sorted { sortLargestFirst ? $0.byteCount > $1.byteCount : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func count(for category: CleanupCategory) -> Int { items.filter { $0.category == category }.count }
    func size(for category: CleanupCategory) -> Int64 { items.filter { $0.category == category }.reduce(0) { $0 + $1.byteCount } }
    func toggle(_ item: StorageItem) {
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }
    func selectFiltered() { selectedIDs.formUnion(filteredItems.map(\.id)) }
    func reset() {
        guard !isBusy else { return }
        phase = .ready; items = []; selectedIDs = []; filter = nil; query = ""; notice = nil; issues = []
    }
    func cancelScan() { task?.cancel() }
    func reveal(_ item: StorageItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func startScan() {
        guard !isBusy, !enabledCategories.isEmpty else { return }
        items = []; selectedIDs = []; issues = []; notice = nil; error = nil; filter = nil; query = ""
        progressCount = 0; progressPath = "Preparing scan…"; phase = .scanning
        do {
            let configuration: ScanConfiguration
            if isDemo { configuration = try makeDemoConfiguration() }
            else { configuration = ScanConfiguration(roots: ScanConfiguration.standard.roots.filter { enabledCategories.contains($0.category) }) }
            scanConfiguration = configuration
            task = Task { [weak self] in
                do {
                    let result = try await StorageScanner().scan(configuration: configuration) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard self?.phase == .scanning else { return }
                            self?.progressCount = progress.inspectedCount
                            self?.progressPath = progress.currentPath
                        }
                    }
                    guard let self else { return }
                    self.items = result.items
                    self.issues = result.issues.map { "\($0.path)\n\($0.message)" }
                    self.phase = .results
                    self.lastScanned = Date()
                    self.disk = DiskSnapshot.read()
                } catch is CancellationError {
                    self?.phase = .ready
                    self?.notice = "Scan cancelled. No files were changed."
                } catch {
                    self?.phase = .ready
                    self?.error = "The scan couldn’t finish. \(error.localizedDescription)"
                }
            }
        } catch {
            phase = .ready; self.error = error.localizedDescription
        }
    }

    func cleanSelected() {
        guard !isDemo, !selectedItems.isEmpty, !isBusy, let configuration = scanConfiguration else { return }
        let reviewed = selectedItems
        showReview = false; phase = .cleaning
        task = Task { [weak self] in
            do {
                let result = try await StorageCleaner().clean(reviewedItems: reviewed, configuration: configuration)
                guard let self else { return }
                let moved = Set(result.movedItems.map(\.id))
                self.items.removeAll { moved.contains($0.id) }
                self.selectedIDs.subtract(moved)
                self.notice = result.movedItems.isEmpty ? nil : "Moved \(result.movedItems.count) \(result.movedItems.count == 1 ? "file" : "files") to Trash. Space is freed when you empty Trash in Finder."
                if !result.failedItems.isEmpty {
                    self.issues.append(contentsOf: result.failedItems.map { "\($0.item.path)\n\($0.message)" })
                    self.error = "\(result.failedItems.count) \(result.failedItems.count == 1 ? "file couldn’t" : "files couldn’t") be moved. They remain selected. View scan notices for details, then rescan before trying again."
                }
                self.phase = .results; self.disk = DiskSnapshot.read()
            } catch {
                self?.phase = .results
                self?.error = "Cleanup couldn’t finish. \(error.localizedDescription)"
            }
        }
    }

    func removeDemoFiles() {
        guard let root = demoRoot,
              root.lastPathComponent.hasPrefix("MacTools-Demo-"),
              root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// An explicitly labeled UI preview uses only disposable temporary fixtures.
    private func makeDemoConfiguration() throws -> ScanConfiguration {
        let root: URL
        if let demoRoot { root = demoRoot }
        else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MacTools-Demo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            demoRoot = root
            let examples: [(CleanupCategory, String, Int64)] = [
                (.caches, "com.example.browser/Media cache", 2_580_000),
                (.caches, "com.example.editor/Workspace cache", 1_460_000),
                (.logs, "Archive/diagnostics.log", 180_000),
                (.downloads, "Design resources.zip", 8_150_000),
                (.downloads, "App installer.dmg", 4_320_000),
                (.largeFiles, "Screen recording.mov", 14_700_000),
                (.largeFiles, "Project archive.zip", 6_820_000)
            ]
            for (category, name, size) in examples {
                let url = root.appendingPathComponent(category.rawValue).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x61, count: Int(size)).write(to: url)
            }
        }
        return ScanConfiguration(roots: CleanupCategory.allCases.filter { enabledCategories.contains($0) }.map {
            ScanRoot(url: root.appendingPathComponent($0.rawValue), category: $0)
        }, largeFileThresholdBytes: 1_000_000)
    }
}
