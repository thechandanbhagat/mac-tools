import Darwin
import Foundation

/// An immutable item choice captured before the UI asks for confirmation.
/// Construction is restricted to a current scan result plus fresh path checks.
struct StorageMapTrashRequest: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    var name: String { url.lastPathComponent }
    var isDirectory: Bool { FileSafety.isDirectory(snapshot) }
    /// Full regular-file allocation, including hidden descendants for folders.
    /// Independent of the map's hard-link attribution or partial scan totals.
    let byteCount: Int64
    fileprivate let rootURL: URL
    fileprivate let rootIdentity: FileIdentity
    fileprivate let snapshot: FileSnapshot
    fileprivate let ancestorIdentities: [String: FileIdentity]
    fileprivate let directoryContents: StorageMapFolderSnapshot?

    fileprivate init(
        url: URL, rootURL: URL, rootIdentity: FileIdentity, snapshot: FileSnapshot,
        ancestorIdentities: [String: FileIdentity], directoryContents: StorageMapFolderSnapshot?
    ) {
        self.url = url
        self.byteCount = directoryContents?.byteCount ?? snapshot.allocatedBytes
        self.rootURL = rootURL
        self.rootIdentity = rootIdentity
        self.snapshot = snapshot
        self.ancestorIdentities = ancestorIdentities
        self.directoryContents = directoryContents
    }
}

struct StorageMapTrash: Sendable {
    typealias TrashHandler = @Sendable (URL) throws -> Void
    private let trashItem: TrashHandler

    init(trashItem: @escaping TrashHandler = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.trashItem = trashItem
    }

    static func prepare(node: StorageMapNode, in result: StorageMapResult) throws -> StorageMapTrashRequest {
        guard let root = result.nodes[result.rootID], root.id == result.rootID,
              root.isDirectory, !root.isPackage,
              let rootSnapshot = root.snapshot, FileSafety.isDirectory(rootSnapshot),
              let scanned = result.nodes[node.id], root.childIDs.contains(node.id),
              scanned.id == scanned.url.path, scanned.url == node.url,
              scanned.snapshot == node.snapshot,
              !scanned.isPackage, let snapshot = scanned.snapshot,
              (scanned.isDirectory ? FileSafety.isDirectory(snapshot) : FileSafety.isRegularFile(snapshot)) else {
            throw FileSafetyError.refused("Rescan this folder before moving the item to Trash.")
        }
        let validated = try StorageMapTrashPath.validate(
            fileURL: scanned.url, rootURL: root.url, rootIdentity: rootSnapshot.identity,
            snapshot: snapshot, expectedAncestors: nil, expectedContents: nil
        )
        return StorageMapTrashRequest(
            url: scanned.url, rootURL: root.url, rootIdentity: rootSnapshot.identity,
            snapshot: snapshot, ancestorIdentities: validated.ancestors,
            directoryContents: validated.contents
        )
    }

    /// Only invoke after the user confirms this exact request. Failure never
    /// falls back to permanent deletion or elevated privileges.
    func moveToTrash(request: StorageMapTrashRequest) async throws {
        try Task.checkCancellation()
        let handler = trashItem
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            _ = try StorageMapTrashPath.validate(
                fileURL: request.url, rootURL: request.rootURL, rootIdentity: request.rootIdentity,
                snapshot: request.snapshot, expectedAncestors: request.ancestorIdentities,
                expectedContents: request.directoryContents
            )
            try Task.checkCancellation()
            // FileManager accepts a path, not an open descriptor. These fresh
            // checks narrow, but cannot eliminate, the final path-operation race.
            try handler(request.url)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

fileprivate struct StorageMapFolderSnapshot: Equatable, Sendable {
    let entries: [String: FileSnapshot]
    let byteCount: Int64
}

private enum StorageMapTrashPath {
    static func validate(
        fileURL: URL, rootURL: URL, rootIdentity: FileIdentity,
        snapshot: FileSnapshot, expectedAncestors: [String: FileIdentity]?,
        expectedContents: StorageMapFolderSnapshot?
    ) throws -> (ancestors: [String: FileIdentity], contents: StorageMapFolderSnapshot?) {
        try Task.checkCancellation()
        guard rootURL.isFileURL, fileURL.isFileURL,
              rootURL.path == rootURL.standardized.path,
              fileURL.path == fileURL.standardized.path,
              fileURL.deletingLastPathComponent().path == rootURL.path,
              fileURL.path != rootURL.path else {
            throw FileSafetyError.refused("This item is outside the displayed folder. Rescan before moving it to Trash.")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(rootURL) }
        defer { if descriptor >= 0 { close(descriptor) } }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        var ancestors: [String: FileIdentity] = [:]
        var rootMetadata = stat()
        guard fstat(descriptor, &rootMetadata) == 0 else { throw posixError(cursor) }
        ancestors[cursor.path] = FileSafety.snapshot(from: rootMetadata).identity

        let components = Array(rootURL.pathComponents.dropFirst())
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            cursor.appendPathComponent(component, isDirectory: true)
            var beforeOpen = stat()
            let statResult = descriptor >= 0
                ? fstatat(descriptor, component, &beforeOpen, AT_SYMLINK_NOFOLLOW)
                : lstat(cursor.path, &beforeOpen)
            guard statResult == 0 else { throw posixError(cursor) }
            guard beforeOpen.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw FileSafetyError.refused("This folder's path changed or contains a symbolic link. Rescan before moving items to Trash.")
            }
            try validateLocation(cursor, metadata: beforeOpen)
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            let next = descriptor >= 0
                ? openat(descriptor, component, flags)
                : open(cursor.path, flags)
            if next < 0 {
                let isFinal = index == components.count - 1
                if !isFinal && (errno == EPERM || errno == EACCES) {
                    if descriptor >= 0 {
                        close(descriptor)
                        descriptor = -1
                    }
                    rootMetadata = beforeOpen
                    ancestors[cursor.path] = FileSafety.snapshot(from: beforeOpen).identity
                    continue
                }
                throw posixError(cursor)
            }
            var opened = stat()
            guard fstat(next, &opened) == 0 else {
                close(next)
                throw posixError(cursor)
            }
            guard FileSafety.snapshot(from: beforeOpen).identity == FileSafety.snapshot(from: opened).identity else {
                close(next)
                throw changedFolder()
            }
            if descriptor >= 0 { close(descriptor) }
            descriptor = next
            rootMetadata = opened
            ancestors[cursor.path] = FileSafety.snapshot(from: opened).identity
        }
        guard descriptor >= 0 else { throw posixError(rootURL) }
        guard FileSafety.snapshot(from: rootMetadata).identity == rootIdentity,
              expectedAncestors == nil || expectedAncestors == ancestors else { throw changedFolder() }
        var metadata = stat()
        guard fstatat(descriptor, fileURL.lastPathComponent, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(fileURL) }
        let current = FileSafety.snapshot(from: metadata)
        guard (FileSafety.isRegularFile(current) || FileSafety.isDirectory(current)), current == snapshot else { throw changedItem() }
        try validateLocation(fileURL, metadata: metadata)
        var contents: StorageMapFolderSnapshot?
        if FileSafety.isDirectory(current) {
            let childDescriptor = openat(descriptor, fileURL.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard childDescriptor >= 0 else { throw posixError(fileURL) }
            defer { close(childDescriptor) }
            var worker = StorageMapFolderValidator(rootURL: fileURL, rootDevice: metadata.st_dev)
            contents = try worker.inspect(descriptor: childDescriptor, expected: snapshot)
            guard expectedContents == nil || expectedContents == contents else { throw changedItem() }
        }
        try Task.checkCancellation()
        // Resource queries use URLs; check the complete path again after them
        // to reject replacements while those queries were running.
        for (path, identity) in ancestors {
            let fresh = try FileSafety.snapshot(of: URL(fileURLWithPath: path, isDirectory: true))
            guard FileSafety.isDirectory(fresh), fresh.identity == identity else { throw changedFolder() }
        }
        let fresh = try FileSafety.snapshot(of: fileURL)
        guard fresh == snapshot else { throw changedItem() }
        return (ancestors, contents)
    }

    static func validateLocation(_ url: URL, metadata: stat) throws {
        let components = url.pathComponents
        let knownCloud = zip(components, components.dropFirst()).contains {
            $0.0 == "Library" && ($0.1 == "CloudStorage" || $0.1 == "Mobile Documents")
        }
        guard !knownCloud, metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw FileSafetyError.refused("Cloud items, placeholders, and folders containing them cannot be moved to Trash from Storage Map.")
        }
        let values = try FileSafety.freshResourceValues(of: url, forKeys: [.isPackageKey, .isUbiquitousItemKey])
        guard values.isUbiquitousItem != true else {
            throw FileSafetyError.refused("Cloud items and folders containing them cannot be moved to Trash from Storage Map.")
        }
        guard values.isPackage != true else {
            throw FileSafetyError.refused("Application or document packages, their contents, and folders containing them cannot be moved to Trash from Storage Map.")
        }
    }

    private static func changedFolder() -> FileSafetyError {
        .refused("This folder changed. Rescan before moving items to Trash.")
    }

    static func changedItem() -> FileSafetyError {
        .refused("This item or its contents changed. Rescan before moving it to Trash.")
    }

    static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// The map may omit hidden entries or stop at a scan limit. A folder move must
/// instead account for the entire tree, and retain it for confirmation-time
/// comparison. A refused or incomplete walk never becomes a Trash request.
private struct StorageMapFolderValidator {
    let rootURL: URL
    let rootDevice: dev_t
    private var entries: [String: FileSnapshot] = [:]
    private var visitedDirectories = Set<FileIdentity>()
    private var visitedFiles = Set<FileIdentity>()
    private var byteCount: Int64 = 0
    private var enumeratedCount = 0

    init(rootURL: URL, rootDevice: dev_t) {
        self.rootURL = rootURL
        self.rootDevice = rootDevice
    }

    mutating func inspect(descriptor: Int32, expected: FileSnapshot) throws -> StorageMapFolderSnapshot {
        try walk(descriptor: descriptor, url: rootURL, relativePath: "", expected: expected, depth: 0)
        return StorageMapFolderSnapshot(entries: entries, byteCount: byteCount)
    }

    private mutating func walk(
        descriptor: Int32, url: URL, relativePath: String, expected: FileSnapshot, depth: Int
    ) throws {
        try Task.checkCancellation()
        guard depth <= 64 else {
            throw FileSafetyError.refused("This folder is too deep to verify completely. Move it to Trash in Finder.")
        }
        var directoryMetadata = stat()
        guard fstat(descriptor, &directoryMetadata) == 0 else { throw StorageMapTrashPath.posixError(url) }
        let directorySnapshot = FileSafety.snapshot(from: directoryMetadata)
        guard directorySnapshot == expected, FileSafety.isDirectory(directorySnapshot),
              visitedDirectories.insert(directorySnapshot.identity).inserted else {
            throw StorageMapTrashPath.changedItem()
        }
        entries[relativePath] = directorySnapshot
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw StorageMapTrashPath.posixError(url) }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw StorageMapTrashPath.posixError(url)
        }
        defer { closedir(directory) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw StorageMapTrashPath.posixError(url) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            enumeratedCount += 1
            guard enumeratedCount <= 100_000 else {
                throw FileSafetyError.refused("This folder has too many items to verify completely. Move it to Trash in Finder.")
            }
            guard let name else {
                throw FileSafetyError.refused("A file name could not be read. Move this folder to Trash in Finder.")
            }
            let childURL = url.appendingPathComponent(name)
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            var metadata = stat()
            guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw StorageMapTrashPath.posixError(childURL) }
            let snapshot = FileSafety.snapshot(from: metadata)
            guard FileSafety.isRegularFile(snapshot) || FileSafety.isDirectory(snapshot) else {
                throw FileSafetyError.refused("This folder contains symbolic links or special files. Move it to Trash in Finder.")
            }
            guard metadata.st_dev == rootDevice else {
                throw FileSafetyError.refused("This folder contains another volume. Move it to Trash in Finder.")
            }
            try StorageMapTrashPath.validateLocation(childURL, metadata: metadata)
            if FileSafety.isDirectory(snapshot) {
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childDescriptor >= 0 else { throw StorageMapTrashPath.posixError(childURL) }
                defer { close(childDescriptor) }
                try walk(descriptor: childDescriptor, url: childURL, relativePath: childPath, expected: snapshot, depth: depth + 1)
            } else {
                entries[childPath] = snapshot
                if visitedFiles.insert(snapshot.identity).inserted {
                    let (total, overflow) = byteCount.addingReportingOverflow(snapshot.allocatedBytes)
                    guard !overflow else {
                        throw FileSafetyError.refused("This folder's size could not be verified completely. Move it to Trash in Finder.")
                    }
                    byteCount = total
                }
            }
            guard try FileSafety.snapshot(of: childURL) == snapshot else { throw StorageMapTrashPath.changedItem() }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw StorageMapTrashPath.posixError(url) }
        guard FileSafety.snapshot(from: after) == directorySnapshot,
              try FileSafety.snapshot(of: url) == directorySnapshot else { throw StorageMapTrashPath.changedItem() }
    }
}
