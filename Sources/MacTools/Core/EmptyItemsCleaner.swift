import Darwin
import Foundation

public enum EmptyItemKind: String, CaseIterable, Identifiable, Sendable {
    case emptyFolder = "Empty Folder"
    case brokenSymlink = "Broken Link"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .emptyFolder: "folder.badge.minus"
        case .brokenSymlink: "link"
        }
    }
}

struct EmptyCleanupItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: EmptyItemKind
    let linkDestination: String?
    let modifiedDate: Date
    let snapshot: FileSnapshot
    let parentIdentity: FileIdentity

    init(
        url: URL,
        name: String? = nil,
        kind: EmptyItemKind,
        linkDestination: String? = nil,
        modifiedDate: Date,
        snapshot: FileSnapshot,
        parentIdentity: FileIdentity
    ) {
        let standardized = url.standardized
        self.id = standardized.path
        self.url = standardized
        self.name = name ?? standardized.lastPathComponent
        self.kind = kind
        self.linkDestination = linkDestination
        self.modifiedDate = modifiedDate
        self.snapshot = snapshot
        self.parentIdentity = parentIdentity
    }
}

struct EmptyItemsScanReport: Equatable, Sendable {
    let rootURL: URL
    let items: [EmptyCleanupItem]
    let issues: [ScanIssue]
    let inspectedCount: Int
}

struct EmptyItemsCleanupOutcome: Equatable, Sendable {
    let trashed: [EmptyCleanupItem]
    let issues: [ScanIssue]
}

enum EmptyItemsCleaner {
    typealias TrashHandler = (URL) throws -> Void

    static func scan(
        root rawRoot: URL,
        maxDepth: Int = 16,
        maxEntries: Int = 100_000
    ) throws -> EmptyItemsScanReport {
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

        var worker = EmptyItemsWorker(
            rootURL: rootURL,
            rootDevice: openedStat.st_dev,
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
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        return EmptyItemsScanReport(
            rootURL: rootURL,
            items: sorted,
            issues: worker.issues,
            inspectedCount: worker.inspectedCount
        )
    }

    static func moveToTrash(
        items: [EmptyCleanupItem],
        root rawRoot: URL,
        trashItem: TrashHandler = { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
    ) throws -> EmptyItemsCleanupOutcome {
        try Task.checkCancellation()
        let rootURL = rawRoot.standardized
        _ = try DuplicateFileAccess.validate(rootURL, directory: true)

        var trashed: [EmptyCleanupItem] = []
        var issues: [ScanIssue] = []

        for item in items {
            try Task.checkCancellation()
            let itemURL = item.url.standardized
            let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            guard itemURL.path.hasPrefix(rootPrefix) && itemURL.path != rootURL.path else {
                issues.append(ScanIssue(path: itemURL.path, message: "Skipped because it is outside the scanned folder."))
                continue
            }
            do {
                let parentURL = itemURL.deletingLastPathComponent()
                let parentSnapshot = try FileSafety.snapshot(of: parentURL)
                guard FileSafety.isDirectory(parentSnapshot),
                      parentSnapshot.identity == item.parentIdentity else {
                    issues.append(ScanIssue(path: itemURL.path, message: "Skipped because its parent folder changed since scanning."))
                    continue
                }

                let currentSnapshot = try FileSafety.snapshot(of: itemURL)
                guard currentSnapshot.identity == item.snapshot.identity else {
                    issues.append(ScanIssue(path: itemURL.path, message: "Skipped because the item changed since scanning."))
                    continue
                }

                switch item.kind {
                case .emptyFolder:
                    guard FileSafety.isDirectory(currentSnapshot) else {
                        issues.append(ScanIssue(path: itemURL.path, message: "Skipped because it is no longer a folder."))
                        continue
                    }
                    let dirFD = Darwin.open(itemURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard dirFD >= 0 else {
                        issues.append(ScanIssue(path: itemURL.path, message: "Couldn’t verify that the folder is still empty."))
                        continue
                    }
                    defer { close(dirFD) }
                    let names = try EmptyItemsWorker.listNames(descriptor: dirFD, url: itemURL)
                    guard names.isEmpty else {
                        issues.append(ScanIssue(path: itemURL.path, message: "Skipped because the folder is no longer empty."))
                        continue
                    }

                case .brokenSymlink:
                    guard FileSafety.isSymlink(currentSnapshot) else {
                        issues.append(ScanIssue(path: itemURL.path, message: "Skipped because it is no longer a symbolic link."))
                        continue
                    }
                    var targetStat = stat()
                    let statResult = stat(itemURL.path, &targetStat)
                    let statErrno = errno
                    guard statResult != 0 && statErrno == ENOENT else {
                        issues.append(ScanIssue(path: itemURL.path, message: "Skipped because the symbolic link target now exists."))
                        continue
                    }
                }

                try trashItem(itemURL)
                trashed.append(item)
            } catch {
                issues.append(ScanIssue(path: itemURL.path, message: error.localizedDescription))
            }
        }

        return EmptyItemsCleanupOutcome(trashed: trashed, issues: issues)
    }
}

private struct EmptyItemsWorker {
    let rootURL: URL
    let rootDevice: dev_t
    let maxDepth: Int
    let maxEntries: Int

    var items: [EmptyCleanupItem] = []
    var issues: [ScanIssue] = []
    var inspectedCount = 0
    private var visitedDirectories = Set<FileIdentity>()

    init(rootURL: URL, rootDevice: dev_t, maxDepth: Int, maxEntries: Int) {
        self.rootURL = rootURL
        self.rootDevice = rootDevice
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

        let names = try Self.listNames(descriptor: descriptor, url: url)
        for name in names {
            try Task.checkCancellation()
            guard inspectedCount < maxEntries else {
                issues.append(ScanIssue(path: rootURL.path, message: "Reached the scan item limit; some items were skipped."))
                return
            }
            if name.hasPrefix(".") { continue }
            inspectedCount += 1

            var childStat = stat()
            guard fstatat(descriptor, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard childStat.st_dev == rootDevice, childStat.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
            let snapshot = FileSafety.snapshot(from: childStat)
            let modifiedDate = Date(
                timeIntervalSince1970: TimeInterval(childStat.st_mtimespec.tv_sec)
                    + TimeInterval(childStat.st_mtimespec.tv_nsec) / 1_000_000_000
            )

            if FileSafety.isSymlink(snapshot) {
                var targetStat = stat()
                if fstatat(descriptor, name, &targetStat, 0) != 0 && errno == ENOENT {
                    let childURL = url.appendingPathComponent(name, isDirectory: false)
                    let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: childURL.path)
                    items.append(
                        EmptyCleanupItem(
                            url: childURL,
                            name: name,
                            kind: .brokenSymlink,
                            linkDestination: destination,
                            modifiedDate: modifiedDate,
                            snapshot: snapshot,
                            parentIdentity: directoryIdentity
                        )
                    )
                }
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

                let subNames = try Self.listNames(descriptor: childDescriptor, url: childURL)
                if subNames.isEmpty {
                    items.append(
                        EmptyCleanupItem(
                            url: childURL,
                            name: name,
                            kind: .emptyFolder,
                            modifiedDate: modifiedDate,
                            snapshot: FileSafety.snapshot(from: openedStat),
                            parentIdentity: directoryIdentity
                        )
                    )
                } else {
                    try walk(
                        descriptor: childDescriptor,
                        url: childURL,
                        directoryIdentity: snapshot.identity,
                        depth: depth + 1
                    )
                }
            }
        }
    }

    static func listNames(descriptor: Int32, url: URL) throws -> [String] {
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
