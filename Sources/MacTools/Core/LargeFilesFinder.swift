import Darwin
import Foundation

public enum LargeFileKind: String, CaseIterable, Identifiable, Sendable {
    case archives = "Archives & Disk Images"
    case media = "Media & Video"
    case documents = "Documents & Data"
    case other = "Other"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .archives: "doc.zipper"
        case .media: "film"
        case .documents: "doc.richtext"
        case .other: "doc"
        }
    }

    public static func classify(fileName: String) -> LargeFileKind {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "ipsw":
            return .archives
        case "mov", "mp4", "mkv", "avi", "m4v", "webm", "mp3", "wav", "flac", "m4a", "aiff", "psd", "tiff", "tif", "heic", "png", "jpg", "jpeg":
            return .media
        case "pdf", "pptx", "key", "docx", "pages", "xlsx", "numbers", "sqlite", "db", "csv", "json", "parquet":
            return .documents
        default:
            return .other
        }
    }
}

public enum LargeFileThreshold: Int64, CaseIterable, Identifiable, Sendable {
    case mb10 = 10_000_000
    case mb50 = 50_000_000
    case mb250 = 250_000_000
    case gb1 = 1_000_000_000

    public var id: Int64 { rawValue }

    public var title: String {
        switch self {
        case .mb10: "10 MB+"
        case .mb50: "50 MB+"
        case .mb250: "250 MB+"
        case .gb1: "1 GB+"
        }
    }
}

public enum StaleFileAgeFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any age"
    case days30 = "30+ days"
    case months6 = "6+ months"
    case year1 = "1+ year"

    public var id: String { rawValue }

    public var minimumAgeSeconds: TimeInterval? {
        switch self {
        case .any: nil
        case .days30: 30 * 86_400
        case .months6: 180 * 86_400
        case .year1: 365 * 86_400
        }
    }
}

struct LargeFileItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: LargeFileKind
    let byteCount: Int64
    let modifiedDate: Date
    let snapshot: FileSnapshot
    let parentIdentity: FileIdentity

    init(
        url: URL,
        name: String? = nil,
        kind: LargeFileKind? = nil,
        byteCount: Int64,
        modifiedDate: Date,
        snapshot: FileSnapshot,
        parentIdentity: FileIdentity
    ) {
        let standardized = url.standardized
        self.id = standardized.path
        self.url = standardized
        let resolvedName = name ?? standardized.lastPathComponent
        self.name = resolvedName
        self.kind = kind ?? LargeFileKind.classify(fileName: resolvedName)
        self.byteCount = byteCount
        self.modifiedDate = modifiedDate
        self.snapshot = snapshot
        self.parentIdentity = parentIdentity
    }
}

struct LargeFileScanReport: Equatable, Sendable {
    let rootURL: URL
    let items: [LargeFileItem]
    let issues: [ScanIssue]
    let inspectedCount: Int

    var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.byteCount }
    }
}

struct LargeFileCleanupOutcome: Equatable, Sendable {
    let trashed: [LargeFileItem]
    let issues: [ScanIssue]

    var reclaimedBytes: Int64 {
        trashed.reduce(0) { $0 + $1.byteCount }
    }
}

enum LargeFilesFinder {
    typealias TrashHandler = (URL) throws -> Void

    static func scan(
        root rawRoot: URL,
        minimumBytes: Int64 = LargeFileThreshold.mb10.rawValue,
        maxDepth: Int = 16,
        maxEntries: Int = 100_000
    ) throws -> LargeFileScanReport {
        try Task.checkCancellation()
        let rootURL = rawRoot.standardized
        let rootSnapshot = try DuplicateFileAccess.validate(rootURL, directory: true)
        let rootDescriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: rootURL.path])
        }
        defer { close(rootDescriptor) }

        var openedStat = stat()
        guard fstat(rootDescriptor, &openedStat) == 0,
              FileSafety.snapshot(from: openedStat).identity == rootSnapshot.identity else {
            throw FileSafetyError.refused("The selected folder changed while starting the scan.")
        }

        var worker = LargeFilesWorker(
            rootURL: rootURL,
            rootDevice: openedStat.st_dev,
            minimumBytes: minimumBytes,
            maxDepth: maxDepth,
            maxEntries: maxEntries
        )
        try worker.walk(
            descriptor: rootDescriptor,
            url: rootURL,
            directoryIdentity: rootSnapshot.identity,
            depth: 0
        )
        let sorted = worker.items.sorted { lhs, rhs in
            if lhs.byteCount != rhs.byteCount { return lhs.byteCount > rhs.byteCount }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return LargeFileScanReport(
            rootURL: rootURL,
            items: sorted,
            issues: worker.issues,
            inspectedCount: worker.inspectedCount
        )
    }

    static func moveToTrash(
        items: [LargeFileItem],
        root rawRoot: URL,
        trashItem: TrashHandler = { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
    ) throws -> LargeFileCleanupOutcome {
        try Task.checkCancellation()
        let rootURL = rawRoot.standardized
        _ = try DuplicateFileAccess.validate(rootURL, directory: true)

        var trashed: [LargeFileItem] = []
        var issues: [ScanIssue] = []

        for item in items {
            try Task.checkCancellation()
            let fileURL = item.url.standardized
            guard FileSafety.isDescendant(fileURL, of: rootURL) else {
                issues.append(ScanIssue(path: fileURL.path, message: "Skipped because it is outside the scanned folder."))
                continue
            }
            do {
                let parentURL = fileURL.deletingLastPathComponent()
                let parentSnapshot = try FileSafety.snapshot(of: parentURL)
                guard FileSafety.isDirectory(parentSnapshot),
                      parentSnapshot.identity == item.parentIdentity else {
                    issues.append(ScanIssue(path: fileURL.path, message: "Skipped because its parent folder changed since scanning."))
                    continue
                }
                let currentSnapshot = try DuplicateFileAccess.validate(fileURL, directory: false)
                guard currentSnapshot == item.snapshot else {
                    issues.append(ScanIssue(path: fileURL.path, message: "Skipped because the file changed since scanning. Rescan before moving it to Trash."))
                    continue
                }
                try trashItem(fileURL)
                trashed.append(item)
            } catch {
                issues.append(ScanIssue(path: fileURL.path, message: error.localizedDescription))
            }
        }
        return LargeFileCleanupOutcome(trashed: trashed, issues: issues)
    }
}

private struct LargeFilesWorker {
    let rootURL: URL
    let rootDevice: dev_t
    let minimumBytes: Int64
    let maxDepth: Int
    let maxEntries: Int

    var items: [LargeFileItem] = []
    var issues: [ScanIssue] = []
    var inspectedCount = 0
    private var visitedDirectories = Set<FileIdentity>()
    private var visitedFiles = Set<FileIdentity>()

    init(
        rootURL: URL,
        rootDevice: dev_t,
        minimumBytes: Int64,
        maxDepth: Int,
        maxEntries: Int
    ) {
        self.rootURL = rootURL
        self.rootDevice = rootDevice
        self.minimumBytes = minimumBytes
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    mutating func walk(
        descriptor: Int32,
        url: URL,
        directoryIdentity: FileIdentity,
        depth: Int
    ) throws {
        try Task.checkCancellation()
        guard visitedDirectories.insert(directoryIdentity).inserted else { return }
        guard depth <= maxDepth, inspectedCount < maxEntries else { return }

        let names = try listNames(descriptor: descriptor, url: url)
        for name in names {
            try Task.checkCancellation()
            guard inspectedCount < maxEntries else {
                issues.append(ScanIssue(path: rootURL.path, message: "Reached the scan item limit; some files were skipped."))
                return
            }
            if name.hasPrefix(".") { continue }
            inspectedCount += 1

            var childStat = stat()
            guard fstatat(descriptor, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard childStat.st_dev == rootDevice, childStat.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            let snapshot = FileSafety.snapshot(from: childStat)

            if FileSafety.isRegularFile(snapshot) {
                guard visitedFiles.insert(snapshot.identity).inserted else { continue }
                let size = max(snapshot.allocatedBytes, snapshot.logicalBytes)
                guard size >= minimumBytes else { continue }
                let childURL = url.appendingPathComponent(name, isDirectory: false)
                if let values = try? FileSafety.freshResourceValues(of: childURL, forKeys: [.isUbiquitousItemKey, .isPackageKey]),
                   values.isUbiquitousItem == true || values.isPackage == true {
                    continue
                }
                let modifiedDate = Date(
                    timeIntervalSince1970: TimeInterval(childStat.st_mtimespec.tv_sec)
                        + TimeInterval(childStat.st_mtimespec.tv_nsec) / 1_000_000_000
                )
                items.append(
                    LargeFileItem(
                        url: childURL,
                        name: name,
                        byteCount: size,
                        modifiedDate: modifiedDate,
                        snapshot: snapshot,
                        parentIdentity: directoryIdentity
                    )
                )
            } else if FileSafety.isDirectory(snapshot) {
                let childURL = url.appendingPathComponent(name, isDirectory: true)
                if let values = try? FileSafety.freshResourceValues(of: childURL, forKeys: [.isUbiquitousItemKey, .isPackageKey]),
                   values.isUbiquitousItem == true || values.isPackage == true {
                    continue
                }
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childDescriptor >= 0 else { continue }
                defer { close(childDescriptor) }

                var openedStat = stat()
                guard fstat(childDescriptor, &openedStat) == 0,
                      FileSafety.snapshot(from: openedStat).identity == snapshot.identity else {
                    continue
                }
                try walk(
                    descriptor: childDescriptor,
                    url: childURL,
                    directoryIdentity: snapshot.identity,
                    depth: depth + 1
                )
            }
        }
    }

    private func listNames(descriptor: Int32, url: URL) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { closedir(directory) }

        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
                }
                return names.sorted()
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != ".." else { continue }
            names.append(name)
        }
    }
}
