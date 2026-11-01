import AppKit
import Foundation

@MainActor
public final class ChecksumVerifierModel: ObservableObject {
    public typealias InspectWork = @Sendable ([URL]) throws -> ChecksumBatchResult

    @Published public private(set) var records: [ChecksumRecord] = []
    @Published public private(set) var issues: [ChecksumIssue] = []
    @Published public var selectedID: String?
    @Published public var algorithm: ChecksumAlgorithm = .sha256
    @Published public var expectedChecksum: String = "" {
        didSet {
            let length = ChecksumVerifier.normalizeDigest(expectedChecksum).count
            if let matched = ChecksumAlgorithm.allCases.first(where: { $0.expectedHexLength == length }),
               algorithm != matched {
                algorithm = matched
            }
        }
    }
    @Published public private(set) var isComputing = false
    @Published public var banner: String?

    public let isDemo: Bool
    private let inspectWork: InspectWork
    private var computeTask: Task<Void, Never>?
    private var activeGeneration = 0
    private var fileURLs: [URL] = []
    private var demoRoot: URL?

    public init(
        isDemo: Bool = ProcessInfo.processInfo.arguments.contains("--demo"),
        inspectWork: @escaping InspectWork = { try ChecksumVerifier.inspect(urls: $0) }
    ) {
        self.isDemo = isDemo
        self.inspectWork = inspectWork
    }

    public var selectedRecord: ChecksumRecord? {
        if let selectedID, let match = records.first(where: { $0.id == selectedID }) {
            return match
        }
        return records.first
    }

    public func comparison(for record: ChecksumRecord) -> ChecksumComparison {
        guard let digest = record.digest(for: algorithm) else { return .notProvided }
        return ChecksumVerifier.compare(digest: digest, expected: expectedChecksum)
    }

    public var matchingCount: Int {
        records.filter { comparison(for: $0) == .matches }.count
    }

    public func prepareDemoIfNeeded() {
        guard isDemo, fileURLs.isEmpty, records.isEmpty, !isComputing else { return }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacToolsChecksumDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeDemoFiles()
        demoRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archiveURL = root.appendingPathComponent("MacTools-1.2.0.dmg")
        let notesURL = root.appendingPathComponent("ReleaseNotes.txt")
        let configURL = root.appendingPathComponent("checksums.json")

        let archiveData = Data("MacTools release image v1.2.0 build 240".utf8)
        let notesData = Data("Release 1.2.0: Faster storage scanning and native checksum verification.".utf8)
        let configData = Data("{\"version\":\"1.2.0\",\"channel\":\"stable\"}".utf8)

        try? archiveData.write(to: archiveURL)
        try? notesData.write(to: notesURL)
        try? configData.write(to: configURL)

        addFiles([archiveURL, notesURL, configURL])
        if let record = try? ChecksumVerifier.inspectFile(at: archiveURL),
           let digest = record.digest(for: .sha256) {
            expectedChecksum = digest
        }
    }

    public func chooseFiles() {
        guard !isComputing else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Files to Inspect"
        panel.prompt = "Inspect"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    public func addFiles(_ urls: [URL]) {
        guard !isComputing else { return }
        var seen = Set(fileURLs.map { $0.standardizedFileURL.path })
        for url in urls {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                fileURLs.append(standardized)
            }
        }
        recompute()
    }

    public func removeFile(id: String) {
        guard !isComputing else { return }
        fileURLs.removeAll { $0.standardizedFileURL.path == id }
        records.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = records.first?.id
        }
    }

    public func clearFiles() {
        cancel()
        fileURLs = []
        records = []
        issues = []
        selectedID = nil
        banner = nil
    }

    public func recompute() {
        computeTask?.cancel()
        let urls = fileURLs
        guard !urls.isEmpty else {
            records = []
            issues = []
            selectedID = nil
            isComputing = false
            return
        }

        activeGeneration += 1
        let generation = activeGeneration
        isComputing = true
        banner = nil
        let work = inspectWork

        computeTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                try work(urls)
            }.result

            guard generation == self.activeGeneration else { return }
            self.isComputing = false
            self.computeTask = nil

            switch result {
            case .success(let batch):
                self.records = batch.records
                self.issues = batch.issues
                if let selectedID = self.selectedID, batch.records.contains(where: { $0.id == selectedID }) {
                    // Preserve selection
                } else {
                    self.selectedID = batch.records.first?.id
                }
            case .failure(let error) where error is CancellationError:
                break
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }
    }

    public func cancel() {
        activeGeneration += 1
        computeTask?.cancel()
        computeTask = nil
        isComputing = false
    }

    @discardableResult
    public func copySelectedDigest() -> Bool {
        guard let record = selectedRecord, let digest = record.digest(for: algorithm) else { return false }
        return copyDigest(digest)
    }

    @discardableResult
    public func copyDigest(_ digest: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(digest, forType: .string)
        if copied {
            banner = "Copied \(algorithm.rawValue) digest."
        }
        return copied
    }

    public func reveal(_ record: ChecksumRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.url])
    }

    public func removeDemoFiles() {
        guard let demoRoot,
              demoRoot.lastPathComponent.hasPrefix("MacToolsChecksumDemo-"),
              demoRoot.deletingLastPathComponent().path == "/private/tmp" else { return }
        try? FileManager.default.removeItem(at: demoRoot)
        self.demoRoot = nil
    }

    public func shutdown() {
        cancel()
        removeDemoFiles()
    }
}
