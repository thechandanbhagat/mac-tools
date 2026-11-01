import AppKit
import SwiftUI

@MainActor
final class BatchRenamerModel: ObservableObject {
    @Published private(set) var files: [URL] = []
    @Published private(set) var plan: BatchRenamePlan?
    @Published private(set) var pendingPlan: BatchRenamePlan?
    @Published private(set) var isPreviewing = false
    @Published private(set) var isApplying = false
    @Published private(set) var previewError: String?
    @Published private(set) var notice: String?
    @Published private(set) var undoReceipt: BatchRenameReceipt?
    @Published private(set) var pendingIsUndo = false
    @Published var error: String?
    @Published var options = BatchRenameOptions() { didSet { if options != oldValue { refresh() } } }
    let isDemo: Bool
    private let service: BatchRenamer
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var demoRoot: URL?
    init(isDemo: Bool = AppEnvironment.isDemo, service: BatchRenamer = BatchRenamer()) {
        self.isDemo = isDemo; self.service = service
    }
    var isBusy: Bool { isPreviewing || isApplying }
    var canApply: Bool { !isBusy && (plan?.changes.isEmpty == false) && pendingPlan == nil }
    func loadIfNeeded() {
        guard isDemo, files.isEmpty, demoRoot == nil else { return }
        do {
            let root = URL(fileURLWithPath: "/private/tmp/MacTools-RenameDemo-\(UUID().uuidString)", isDirectory: true)
            demoRoot = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let urls = ["Coast.jpg", "Forest.jpg", "Mountains.jpg"].map { root.appendingPathComponent($0) }
            for url in urls { try Data(repeating: 0x61, count: 128).write(to: url) }
            setFiles(urls)
        } catch { self.error = error.localizedDescription }
    }
    func chooseFiles() {
        guard !isApplying else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { addFiles(panel.urls.map { $0.standardized }) }
    }
    func addFiles(_ urls: [URL]) {
        guard !isApplying else { return }
        var seen = Set(files.map { $0.standardized.path })
        var combined = files
        for url in urls {
            let standardized = url.standardized
            if seen.insert(standardized.path).inserted {
                combined.append(standardized)
            }
        }
        setFiles(combined)
    }
    func removeFile(_ url: URL) {
        guard !isApplying else { return }
        let path = url.standardized.path
        setFiles(files.filter { $0.standardized.path != path })
    }
    func clearFiles() {
        guard !isApplying else { return }
        setFiles([])
    }
    func setFiles(_ urls: [URL]) {
        guard !isApplying else { return }
        files = urls; notice = nil; error = nil
        refresh()
    }
    func refresh() {
        guard !isApplying else { return }
        token = UUID(); let generation = token
        task?.cancel(); pendingPlan = nil; pendingIsUndo = false; plan = nil; previewError = nil
        guard !files.isEmpty else { isPreviewing = false; task = nil; return }
        isPreviewing = true
        let operation = service, urls = files, settings = options
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) { try operation.preview(files: urls, options: settings) }
                let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.token == generation, !Task.isCancelled else { return }
                self.plan = plan; self.isPreviewing = false; self.task = nil
            } catch {
                guard let self, self.token == generation else { return }
                self.isPreviewing = false; self.task = nil
                if !(error is CancellationError) { self.previewError = error.localizedDescription }
            }
        }
    }
    func review() { if canApply { pendingIsUndo = false; pendingPlan = plan } }
    func reviewUndo() {
        guard !isBusy, let receipt = undoReceipt else { return }
        pendingIsUndo = true; pendingPlan = receipt.undoPlan
    }
    func cancelReview() { if !isApplying { pendingPlan = nil; pendingIsUndo = false } }
    func confirm() {
        guard !isDemo, !isBusy, let pendingPlan else { return }
        let isUndo = pendingIsUndo
        self.pendingPlan = nil; pendingIsUndo = false
        isApplying = true; notice = nil; error = nil
        token = UUID(); let generation = token, operation = service
        task = Task { [weak self] in
            do {
                let receipt = try await operation.apply(pendingPlan)
                guard let self, self.token == generation else { return }
                self.isApplying = false; self.task = nil
                self.undoReceipt = isUndo ? nil : receipt
                let destinations = Dictionary(uniqueKeysWithValues: pendingPlan.entries.map { ($0.source, $0.destination) })
                self.files = self.files.map { destinations[$0] ?? $0 }
                self.refresh()
                self.notice = isUndo ? "Original names restored." : "Renamed \(pendingPlan.changes.count) \(pendingPlan.changes.count == 1 ? "file" : "files")."
            } catch {
                guard let self, self.token == generation else { return }
                self.isApplying = false; self.task = nil
                self.error = error.localizedDescription
                self.refresh()
            }
        }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func finishPendingOperation() async {
        if isApplying { await task?.value }
    }
    func shutdown() {
        token = UUID(); task?.cancel(); task = nil
        if let root = demoRoot, root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix("MacTools-RenameDemo-") { try? FileManager.default.removeItem(at: root) }
    }
}
