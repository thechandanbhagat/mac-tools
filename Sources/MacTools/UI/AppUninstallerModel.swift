import AppKit
import SwiftUI

@MainActor
final class AppUninstallerModel: ObservableObject {
    enum Phase { case idle, loading, inspecting, uninstalling }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var applications: [UninstallApplication] = []
    @Published private(set) var selectedApplication: UninstallApplication?
    @Published private(set) var inspection: AppUninstallerInspection?
    @Published private(set) var selectedRelatedIDs: Set<String> = []
    @Published private(set) var pendingRequest: AppUninstallerRequest?
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var notice: String?
    @Published private(set) var hasLoaded = false
    @Published var query = ""
    @Published var error: String?
    @Published var showIssues = false

    let isDemo: Bool
    private var service: AppUninstaller
    private let usesDemoFixtures: Bool
    private var demoRoot: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(isDemo: Bool = AppEnvironment.isDemo, service: AppUninstaller? = nil) {
        self.isDemo = isDemo
        self.service = service ?? AppUninstaller()
        self.usesDemoFixtures = isDemo && service == nil
    }

    var isBusy: Bool { phase != .idle }
    var isUninstalling: Bool { phase == .uninstalling }
    var filteredApplications: [UninstallApplication] {
        applications.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || $0.url.path.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
    var selectedItems: [UninstallItem] {
        guard let inspection else { return [] }
        return [inspection.appItem] + inspection.relatedItems.filter { selectedRelatedIDs.contains($0.id) }
    }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.byteCount } }
    var canReview: Bool {
        guard !isBusy, pendingRequest == nil, let inspection else { return false }
        return !inspection.isRunning && !inspection.appItem.isPartial
    }

    func loadIfNeeded() { if !hasLoaded && !isBusy { refresh() } }

    func refresh() {
        guard !isUninstalling else { return }
        invalidate()
        selectedApplication = nil
        inspection = nil
        selectedRelatedIDs = []
        notice = nil
        error = nil
        issues = []
        phase = .loading
        do {
            if usesDemoFixtures && demoRoot == nil { service = try makeDemoService() }
        } catch {
            phase = .idle
            self.error = error.localizedDescription
            return
        }
        let operation = service
        let token = generation
        task = Task { [weak self] in
            do {
                let result = try await operation.inventory()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.applications = result.applications
                self.issues = result.issues
                self.hasLoaded = true
                self.phase = .idle
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .idle
                self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func select(_ application: UninstallApplication) {
        guard !isUninstalling, phase != .loading,
              let current = applications.first(where: { $0.id == application.id }) else { return }
        invalidate()
        selectedApplication = current
        inspection = nil
        selectedRelatedIDs = []
        notice = nil
        error = nil
        phase = .inspecting
        let operation = service
        let token = generation
        task = Task { [weak self] in
            do {
                let result = try await operation.inspect(application: current)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.inspection = result
                self.phase = .idle
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.phase = .idle
                self.task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func toggleRelated(_ item: UninstallItem) {
        guard !isBusy, pendingRequest == nil, !item.isPartial,
              inspection?.relatedItems.contains(where: { $0.id == item.id }) == true else { return }
        if selectedRelatedIDs.contains(item.id) { selectedRelatedIDs.remove(item.id) }
        else { selectedRelatedIDs.insert(item.id) }
    }

    func selectAllRelated() {
        guard !isBusy, pendingRequest == nil, let inspection else { return }
        selectedRelatedIDs = Set(inspection.relatedItems.filter { !$0.isPartial }.map(\.id))
    }

    func clearRelatedSelection() {
        guard !isBusy, pendingRequest == nil else { return }
        selectedRelatedIDs = []
    }

    func review() {
        guard canReview, let inspection else { return }
        do { pendingRequest = try service.prepare(inspection: inspection, selectedRelatedIDs: selectedRelatedIDs) }
        catch { self.error = error.localizedDescription }
    }

    func cancelReview() { if !isUninstalling { pendingRequest = nil } }

    func confirmUninstall() {
        guard !isDemo, !isBusy, let request = pendingRequest else { return }
        pendingRequest = nil
        phase = .uninstalling
        notice = nil
        error = nil
        let token = UUID()
        generation = token
        let operation = service
        task = Task { [weak self] in
            let result = await operation.moveToTrash(request: request)
            guard let self, self.generation == token else { return }
            self.phase = .idle
            self.task = nil
            self.inspection = nil
            self.selectedRelatedIDs = []
            if result.movedItems.contains(where: { $0.url == request.application.url }) {
                self.applications.removeAll { $0.id == request.application.id }
                self.selectedApplication = nil
            }
            if !result.movedItems.isEmpty {
                self.notice = "Moved \(result.movedItems.count) \(result.movedItems.count == 1 ? "item" : "items") to Trash."
            }
            if !result.failures.isEmpty {
                self.issues.append(contentsOf: result.failures.map { ScanIssue(path: $0.item.url.path, message: $0.message) })
                self.error = result.failures.map { "\($0.item.name): \($0.message)" }.joined(separator: "\n\n")
            } else if result.isCancelled { self.notice = "Uninstall cancelled." }
        }
    }

    func cancelScan() {
        guard phase == .loading || phase == .inspecting else { return }
        invalidate()
        phase = .idle
        notice = "Scan cancelled."
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    var allIssues: [ScanIssue] { issues + (inspection?.issues ?? []) }

    private func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        pendingRequest = nil
    }

    func shutdown() {
        invalidate()
        guard let root = demoRoot, root.lastPathComponent.hasPrefix("MacTools-UninstallerDemo-"),
              root.deletingLastPathComponent().path == "/private/tmp" else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDemoService() throws -> AppUninstaller {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacTools-UninstallerDemo-\(UUID().uuidString)", isDirectory: true)
        demoRoot = root
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let samples = [("Canvas", "com.example.canvas", 4_000_000),
                       ("Noteshelf", "com.example.noteshelf", 2_000_000),
                       ("Soundroom", "com.example.soundroom", 6_000_000)]
        for (name, bundleID, size) in samples {
            let contents = apps.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info: [String: String] = ["CFBundleName": name, "CFBundleIdentifier": bundleID,
                                        "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            try Data(repeating: 0x61, count: size).write(to: contents.appendingPathComponent("Resources/Sample.dat"))
            for (relative, count) in [("Caches/\(bundleID)/Cache.dat", 240_000),
                                      ("Application Support/\(bundleID)/Settings.dat", 80_000)] {
                let file = library.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x61, count: count).write(to: file)
            }
        }
        return AppUninstaller(configuration: .init(applicationRoots: [apps], libraryURL: library, ownApplicationURL: nil),
                              isRunning: { _, _ in false })
    }
}
