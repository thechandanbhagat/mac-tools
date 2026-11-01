import Foundation

/// A read-only view of regular-file allocations. Folder metadata is excluded.
/// A hard-linked file contributes bytes only at its first visited path.
struct StorageMapNode: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let byteCount: Int64
    /// Number of regular-file directory entries, including hard-link aliases.
    let fileCount: Int
    /// Hard-linked directory entries whose bytes were counted at another path.
    let sharedFileCount: Int
    /// Packages are aggregate leaves; their internal entries are not exposed.
    let childIDs: [String]
    let isPartial: Bool
    /// Uncached metadata captured from the scanner's no-follow lookup.
    /// Required before a file can be offered for Trash.
    let snapshot: FileSnapshot?

    init(
        id: String, url: URL, name: String, isDirectory: Bool, isPackage: Bool,
        byteCount: Int64, fileCount: Int, childIDs: [String], isPartial: Bool,
        sharedFileCount: Int = 0, snapshot: FileSnapshot? = nil
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.sharedFileCount = sharedFileCount
        self.childIDs = childIDs
        self.isPartial = isPartial
        self.snapshot = snapshot
    }
}

struct StorageMapResult: Sendable {
    let rootID: String
    let nodes: [String: StorageMapNode]
    let issues: [ScanIssue]
    /// Raw directory entries encountered, including hidden or skipped entries.
    /// This and metadata inspections are bounded by maximumEntries.
    let enumeratedCount: Int
    let inspectedCount: Int
    let reachedLimit: Bool
}

struct StorageMapConfiguration: Sendable {
    var root: URL
    var includeHidden: Bool
    /// Shared limit for all raw directory entries, including package contents
    /// and hidden entries. Hitting the exact cap conservatively marks partial.
    var maximumEntries: Int
    var maximumDepth: Int

    init(root: URL, includeHidden: Bool = true, maximumEntries: Int = 100_000, maximumDepth: Int = 64) {
        // URL.standardized normalizes dot components lexically. The file URL
        // variant can rewrite /private/tmp to its /tmp symlink on macOS.
        self.root = root.standardized
        self.includeHidden = includeHidden
        self.maximumEntries = max(1, maximumEntries)
        self.maximumDepth = max(0, min(128, maximumDepth))
    }
}

enum StorageMapError: LocalizedError {
    case invalidRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let message): message
        }
    }
}
