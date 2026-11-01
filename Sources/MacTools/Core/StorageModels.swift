import Foundation

enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case caches
    case logs
    case downloads
    case largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: "App caches"
        case .logs: "Log files"
        case .downloads: "Downloads"
        case .largeFiles: "Large files"
        }
    }
}

struct ScanRoot: Hashable, Sendable {
    let url: URL
    let category: CleanupCategory

    init(url: URL, category: CleanupCategory) {
        self.url = url.standardizedFileURL
        self.category = category
    }
}

struct ScanConfiguration: Sendable {
    var roots: [ScanRoot]
    var largeFileThresholdBytes: Int64
    var maximumEntries: Int
    var maximumItems: Int

    init(
        roots: [ScanRoot],
        largeFileThresholdBytes: Int64 = 100 * 1_024 * 1_024,
        maximumEntries: Int = 100_000,
        maximumItems: Int = 10_000
    ) {
        self.roots = roots
        self.largeFileThresholdBytes = max(0, largeFileThresholdBytes)
        self.maximumEntries = max(1, maximumEntries)
        self.maximumItems = max(1, maximumItems)
    }

    static var standard: ScanConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ScanConfiguration(roots: [
            ScanRoot(url: home.appendingPathComponent("Library/Caches"), category: .caches),
            ScanRoot(url: home.appendingPathComponent("Library/Logs"), category: .logs),
            ScanRoot(url: home.appendingPathComponent("Downloads"), category: .downloads),
            ScanRoot(url: home.appendingPathComponent("Documents"), category: .largeFiles),
            ScanRoot(url: home.appendingPathComponent("Desktop"), category: .largeFiles)
        ])
    }
}

/// A candidate is an ordinary file, never a folder. Selection belongs to the UI
/// and starts empty; discovering a file is not permission to remove it.
struct StorageItem: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let category: CleanupCategory
    /// Allocated bytes at scan time; APFS sharing/compression can affect actual savings.
    let byteCount: Int64
    let logicalByteCount: Int64
    let modifiedAt: Date
    var name: String { url.lastPathComponent }
    var path: String { url.path }

    // These snapshots cannot be supplied by the UI through a public initializer.
    // A cleanup request must contain candidates created by this scanner.
    let root: ScanRoot
    let canonicalRootURL: URL
    let rootIdentity: FileIdentity
    let snapshot: FileSnapshot
}

struct ScanProgress: Sendable {
    let inspectedCount: Int
    let discoveredBytes: Int64
    let currentPath: String
}

struct ScanIssue: Identifiable, Hashable, Sendable {
    var id: String { path + "\n" + message }
    let path: String
    let message: String
}

struct ScanResult: Sendable {
    let items: [StorageItem]
    let issues: [ScanIssue]
    let inspectedCount: Int
    let reachedLimit: Bool
    var scannedBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

struct CleanupFailure: Identifiable, Sendable {
    var id: String { item.id }
    let item: StorageItem
    let message: String
}

struct CleanupResult: Sendable {
    let movedItems: [StorageItem]
    let failedItems: [CleanupFailure]
    let isCancelled: Bool
    var movedBytes: Int64 { movedItems.reduce(0) { $0 + $1.byteCount } }
}

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct FileSnapshot: Hashable, Sendable {
    let identity: FileIdentity
    let logicalBytes: Int64
    let allocatedBytes: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let mode: UInt16

    var modifiedAt: Date {
        Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }
}
