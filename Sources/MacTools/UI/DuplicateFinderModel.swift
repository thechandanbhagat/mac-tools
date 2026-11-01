import AppKit
import SwiftUI

@MainActor
final class DuplicateFinderModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isTrashing = false
    @Published private(set) var hasScanned = false
    @Published private(set) var pendingRequest: DuplicateTrashRequest?
    @Published private(set) var notice: String?
    @Published var query = ""
    @Published var error: String?
    @Published var showIssues = false
    let isDemo: Bool
    private let service: DuplicateFinder
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var demoRoot: URL?

    init(isDemo: Bool = AppEnvironment.isDemo, service: DuplicateFinder = DuplicateFinder()) {
        self.isDemo = isDemo
        self.service = service
    }
    var isBusy: Bool { isScanning || isTrashing }
    var selectedFiles: [DuplicateFile] { groups.flatMap(\.files).filter { selectedIDs.contains($0.id) } }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.snapshot.allocatedBytes } }
    var filteredGroups: [DuplicateGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains {
                $0.name.localizedCaseInsensitiveContains(trimmed) || $0.url.path.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    func loadIfNeeded() {
        guard isDemo, rootURL == nil else { return }
        do { setRoot(try makeDemo()) } catch { self.error = error.localizedDescription }
    }
    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { setRoot(url.standardized) }
    }
    func setRoot(_ url: URL) {
        guard !isTrashing else { return }
        cancelScan()
        rootURL = url; groups = []; hasScanned = false
        scan()
    }
    func refresh() { scan() }
    func scan() {
        guard !isBusy, let rootURL else { return }
        token = UUID(); let generation = token
        selectedIDs = []; pendingRequest = nil; error = nil; notice = nil; issues = []; groups = []
        isScanning = true
        let operation = service
        task = Task { [weak self] in
            do {
                let result = try await operation.scan(root: rootURL)
                guard let self, self.token == generation, !Task.isCancelled else { return }
                self.groups = result.groups; self.issues = result.issues; self.hasScanned = true
                self.isScanning = false; self.task = nil
            } catch {
                guard let self, self.token == generation else { return }
                self.isScanning = false; self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func cancelScan() {
        guard !isTrashing else { return }
        token = UUID(); task?.cancel(); task = nil; isScanning = false; pendingRequest = nil
    }
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        !isBusy && pendingRequest == nil && (selectedIDs.contains(file.id) || group.files.filter { !selectedIDs.contains($0.id) }.count > 1)
    }
    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard let current = groups.first(where: { $0.id == group.id }), current.files.contains(where: { $0.id == file.id }), canSelect(file, in: current) else { return }
        if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) } else { selectedIDs.insert(file.id) }
    }
    func selectDuplicates() {
        guard !isBusy, pendingRequest == nil else { return }
        var next = Set<String>()
        for group in groups {
            for file in group.files.dropFirst() {
                next.insert(file.id)
            }
        }
        selectedIDs = next
    }
    func clearSelection() {
        guard !isBusy, pendingRequest == nil else { return }
        selectedIDs = []
    }
    func review() {
        guard !isBusy else { return }
        do { pendingRequest = try service.prepare(groups: groups, selectedIDs: selectedIDs) }
        catch { self.error = error.localizedDescription }
    }
    func cancelReview() { if !isTrashing { pendingRequest = nil } }
    func confirmTrash() {
        guard !isDemo, !isBusy, let request = pendingRequest else { return }
        pendingRequest = nil; isTrashing = true; error = nil
        let generation = UUID(); token = generation
        let operation = service
        task = Task { [weak self] in
            let result = await operation.moveToTrash(request)
            guard let self, self.token == generation else { return }
            self.isTrashing = false; self.task = nil
            self.groups = []; self.selectedIDs = []; self.hasScanned = false
            self.scan()
            self.notice = result.movedIDs.isEmpty ? nil : "Moved \(result.movedIDs.count) \(result.movedIDs.count == 1 ? "file" : "files") to Trash."
            if !result.failures.isEmpty { self.error = result.failures.map { "\($0.path): \($0.message)" }.joined(separator: "\n\n") }
        }
    }
    func reveal(_ file: DuplicateFile) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
    func shutdown() {
        token = UUID(); task?.cancel(); task = nil
        if let root = demoRoot, root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix("MacTools-DuplicatesDemo-") { try? FileManager.default.removeItem(at: root) }
    }
    private func makeDemo() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/MacTools-DuplicatesDemo-\(UUID().uuidString)", isDirectory: true)
        demoRoot = root
        for (name, byte, size) in [("Photos/Coast.jpg", UInt8(0x61), 1_200_000), ("Backup/Coast copy.jpg", 0x61, 1_200_000), ("Documents/Notes.txt", 0x62, 24_000), ("Backup/Notes copy.txt", 0x62, 24_000), ("Documents/Unique.txt", 0x63, 400)] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: size).write(to: url)
        }
        return root
    }
}
