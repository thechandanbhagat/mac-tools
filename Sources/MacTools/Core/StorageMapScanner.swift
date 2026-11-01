import Darwin
import Foundation

struct StorageMapScanner: Sendable {
    /// Runs metadata-only work away from the main actor. No file contents are
    /// opened, and cancellation is forwarded to the detached worker.
    func scan(
        configuration: StorageMapConfiguration,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> StorageMapResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            var scanner = StorageMapWorker(configuration: configuration, progress: progress)
            return try scanner.scan()
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct StorageMapWorker {
    let configuration: StorageMapConfiguration
    let progress: @Sendable (ScanProgress) -> Void
    private var nodes: [String: StorageMapNode] = [:]
    private var issues: [ScanIssue] = []
    private var visitedFiles = Set<StorageMapIdentity>()
    private var visitedDirectories = Set<StorageMapIdentity>()
    private var enumeratedCount = 0
    private var inspectedCount = 0
    private var discoveredBytes: Int64 = 0
    private var reachedLimit = false
    private var lastProgress = Date.distantPast
    private var rootDevice: dev_t = 0
    private var skippedLinks = 0
    private var skippedCloud = 0
    private var skippedVolumes = 0
    private var omittedIssueCount = 0

    init(configuration: StorageMapConfiguration, progress: @escaping @Sendable (ScanProgress) -> Void) {
        self.configuration = configuration
        self.progress = progress
    }

    mutating func scan() throws -> StorageMapResult {
        try Task.checkCancellation()
        let root = configuration.root.standardized
        guard root.isFileURL else { throw StorageMapError.invalidRoot("Choose a local folder to map.") }
        let descriptor = try Self.openRoot(root)
        defer { close(descriptor) }
        let metadata = try Self.metadata(descriptor: descriptor, url: root)
        rootDevice = metadata.st_dev
        visitedDirectories.insert(StorageMapIdentity(metadata))
        let package = try Self.isPackage(root)
        _ = try walk(descriptor: descriptor, url: root, depth: 0, isPackage: package, exposeNode: true)
        try Task.checkCancellation()

        if skippedLinks > 0 {
            recordIssue(root, "Skipped \(skippedLinks.formatted()) symbolic links; link targets are never followed.")
        }
        if skippedCloud > 0 {
            recordIssue(root, "Skipped \(skippedCloud.formatted()) cloud locations or placeholders to avoid downloading files.")
        }
        if skippedVolumes > 0 {
            recordIssue(root, "Skipped \(skippedVolumes.formatted()) locations on another volume.")
        }
        if reachedLimit {
            recordIssue(root, "The scan reached its entry or folder-depth limit. Sizes are partial; scan a smaller folder for more detail.")
        }
        if omittedIssueCount > 0 {
            issues.append(ScanIssue(path: root.path, message: "\(omittedIssueCount.formatted()) additional access or scan issues were omitted."))
        }
        progress(ScanProgress(inspectedCount: inspectedCount, discoveredBytes: discoveredBytes, currentPath: "Scan complete"))
        return StorageMapResult(rootID: root.path, nodes: nodes, issues: issues, enumeratedCount: enumeratedCount, inspectedCount: inspectedCount, reachedLimit: reachedLimit)
    }

    /// Each recursive frame owns an open directory, bounded to at most 128
    /// levels. All child lookups are relative to that descriptor, never through
    /// a potentially substituted ancestor path.
    private mutating func walk(
        descriptor: Int32, url: URL, depth: Int, isPackage: Bool, exposeNode: Bool
    ) throws -> StorageMapAggregate {
        try Task.checkCancellation()
        let directorySnapshot = try Self.metadata(descriptor: descriptor, url: url)
        var aggregate = StorageMapAggregate()
        var childIDs: [String] = []
        let atDepthLimit = depth >= max(0, min(128, configuration.maximumDepth))
        let listing: StorageMapListing
        do {
            // A depth-limited folder needs at most one real entry to establish
            // that it may contain uncounted files. Never enumerate its contents.
            listing = try names(in: descriptor, url: url, maximumNames: atDepthLimit ? 1 : Int.max)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordIssue(url, error.localizedDescription)
            aggregate.isPartial = true
            if exposeNode { store(url, isDirectory: true, isPackage: isPackage, aggregate: aggregate, childIDs: [], metadata: directorySnapshot) }
            return aggregate
        }

        if listing.hasMore {
            aggregate.isPartial = true
            reachedLimit = true
        }
        if listing.hadInvalidName { aggregate.isPartial = true }
        if listing.hadInvalidName { recordIssue(url, "Some file names could not be represented and were skipped.") }
        if atDepthLimit, !listing.names.isEmpty {
            aggregate.isPartial = true
            reachedLimit = true
        } else {
            for name in listing.names {
                try Task.checkCancellation()
                // Ancestors may already have collected siblings before a deeper
                // folder consumed the enumeration budget. Retain those entries.
                inspectedCount += 1
                let child = url.appendingPathComponent(name)
                defer { reportProgress(path: child.path) }
                do {
                    var metadata = stat()
                    guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.posixError(child) }
                    let kind = metadata.st_mode & mode_t(S_IFMT)
                    if kind == mode_t(S_IFLNK) {
                        skippedLinks += 1
                        aggregate.isPartial = true
                        continue
                    }
                    if !configuration.includeHidden, metadata.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                    guard metadata.st_dev == rootDevice else {
                        skippedVolumes += 1
                        aggregate.isPartial = true
                        continue
                    }
                    guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else { continue }
                    if try metadata.st_flags & UInt32(SF_DATALESS) != 0 || Self.isCloud(child) {
                        skippedCloud += 1
                        aggregate.isPartial = true
                        continue
                    }
                    let childVisible = exposeNode && !isPackage
                    if kind == mode_t(S_IFREG) {
                        let unique = visitedFiles.insert(StorageMapIdentity(metadata)).inserted
                        let bytes = unique ? max(0, Int64(metadata.st_blocks)) * 512 : 0
                        let entry = StorageMapAggregate(byteCount: bytes, fileCount: 1, sharedFileCount: unique ? 0 : 1)
                        aggregate.add(entry)
                        discoveredBytes += bytes
                        if childVisible {
                            store(child, isDirectory: false, isPackage: false, aggregate: entry, childIDs: [], metadata: metadata)
                            childIDs.append(child.path)
                        }
                    } else {
                        let package = try Self.isPackage(child)
                        var entry = StorageMapAggregate()
                        let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if childDescriptor < 0 {
                            entry.isPartial = true
                            recordIssue(child, Self.posixError(child).localizedDescription)
                            if childVisible { store(child, isDirectory: true, isPackage: package, aggregate: entry, childIDs: [], metadata: metadata) }
                        } else {
                            defer { close(childDescriptor) }
                            let opened = try Self.metadata(descriptor: childDescriptor, url: child)
                            guard StorageMapIdentity(opened) == StorageMapIdentity(metadata), opened.st_dev == rootDevice else {
                                throw StorageMapError.invalidRoot("This folder changed during the scan; scan it again to refresh its size.")
                            }
                            if !visitedDirectories.insert(StorageMapIdentity(opened)).inserted {
                                entry.isPartial = true
                                recordIssue(child, "This directory was already visited and was not counted again.")
                                if childVisible { store(child, isDirectory: true, isPackage: package, aggregate: entry, childIDs: [], metadata: metadata) }
                            } else {
                                entry = try walk(descriptor: childDescriptor, url: child, depth: depth + 1, isPackage: package, exposeNode: childVisible)
                            }
                        }
                        aggregate.add(entry)
                        if childVisible { childIDs.append(child.path) }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    aggregate.isPartial = true
                    recordIssue(child, error.localizedDescription)
                }
            }
        }
        if exposeNode {
            childIDs.sort {
                let left = nodes[$0]?.byteCount ?? 0
                let right = nodes[$1]?.byteCount ?? 0
                return left == right ? $0 < $1 : left > right
            }
            store(url, isDirectory: true, isPackage: isPackage, aggregate: aggregate, childIDs: childIDs, metadata: directorySnapshot)
        }
        return aggregate
    }

    private mutating func store(_ url: URL, isDirectory: Bool, isPackage: Bool, aggregate: StorageMapAggregate, childIDs: [String], metadata: stat) {
        nodes[url.path] = StorageMapNode(
            id: url.path, url: url, name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            isDirectory: isDirectory, isPackage: isPackage, byteCount: aggregate.byteCount,
            fileCount: aggregate.fileCount, childIDs: childIDs, isPartial: aggregate.isPartial,
            sharedFileCount: aggregate.sharedFileCount, snapshot: FileSafety.snapshot(from: metadata)
        )
    }

    private mutating func recordIssue(_ url: URL, _ message: String) {
        // An inaccessible directory can contain many inaccessible entries; keep
        // the result bounded while retaining an honest count of further issues.
        if issues.count < 200 { issues.append(ScanIssue(path: url.path, message: message)) }
        else { omittedIssueCount += 1 }
    }

    private mutating func reportProgress(path: String) {
        if Date().timeIntervalSince(lastProgress) >= 0.08 {
            progress(ScanProgress(inspectedCount: inspectedCount, discoveredBytes: discoveredBytes, currentPath: path))
            lastProgress = Date()
        }
    }

    private static func openRoot(_ url: URL) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(url) }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        let components = Array(url.pathComponents.dropFirst())
        do {
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                cursor.appendPathComponent(component)
                var metadata = stat()
                let statResult = descriptor >= 0
                    ? fstatat(descriptor, component, &metadata, AT_SYMLINK_NOFOLLOW)
                    : lstat(cursor.path, &metadata)
                guard statResult == 0 else { throw posixError(cursor) }
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw StorageMapError.invalidRoot("Choose a folder whose path does not contain symbolic links. Cannot scan \(cursor.path).")
                }
                guard metadata.st_flags & UInt32(SF_DATALESS) == 0, try !isCloud(cursor) else {
                    throw StorageMapError.invalidRoot("Cloud folders and placeholders are excluded to avoid downloading files. Choose a local folder.")
                }
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
                        continue
                    }
                    throw posixError(cursor)
                }
                var opened = stat()
                guard fstat(next, &opened) == 0,
                      FileSafety.snapshot(from: metadata).identity == FileSafety.snapshot(from: opened).identity else {
                    close(next)
                    throw StorageMapError.invalidRoot("Choose a folder whose path did not change while opening \(cursor.path).")
                }
                if descriptor >= 0 { close(descriptor) }
                descriptor = next
            }
            guard descriptor >= 0 else { throw posixError(url) }
            return descriptor
        } catch {
            if descriptor >= 0 { close(descriptor) }
            throw error
        }
    }

    private static func metadata(descriptor: Int32, url: URL) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError(url) }
        return metadata
    }

    private static func isCloud(_ url: URL) throws -> Bool {
        // iCloud and File Provider roots can contain locally downloaded files,
        // but skipping the whole location avoids enumerating online-only trees.
        let components = url.pathComponents
        if zip(components, components.dropFirst()).contains(where: {
            $0.0 == "Library" && ($0.1 == "Mobile Documents" || $0.1 == "CloudStorage")
        }) { return true }
        return try FileSafety.freshResourceValues(of: url, forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
    }

    private static func isPackage(_ url: URL) throws -> Bool {
        try FileSafety.freshResourceValues(of: url, forKeys: [.isPackageKey]).isPackage == true
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }

    private mutating func names(in descriptor: Int32, url: URL, maximumNames: Int) throws -> StorageMapListing {
        let allowance = min(maximumNames, max(0, max(1, configuration.maximumEntries) - enumeratedCount))
        guard allowance > 0 else {
            return StorageMapListing(names: [], hasMore: true, hadInvalidName: false)
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw Self.posixError(url) }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            throw Self.posixError(url)
        }
        defer { closedir(directory) }
        var names: [String] = []
        var count = 0
        var hadInvalidName = false
        while true {
            try Task.checkCancellation()
            // The shared budget bounds readdir work as well as retained names.
            // No extra entry is fetched to prove EOF when the budget is spent.
            guard count < allowance else {
                return StorageMapListing(names: names.sorted(), hasMore: true, hadInvalidName: hadInvalidName)
            }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw Self.posixError(url) }
                return StorageMapListing(names: names.sorted(), hasMore: false, hadInvalidName: hadInvalidName)
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingCString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            enumeratedCount += 1
            reportProgress(path: url.path)
            guard let name else { hadInvalidName = true; continue }
            guard configuration.includeHidden || !name.hasPrefix(".") else { continue }
            names.append(name)
        }
    }
}

private struct StorageMapIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        birthSeconds = metadata.st_birthtimespec.tv_sec
        birthNanoseconds = metadata.st_birthtimespec.tv_nsec
    }
}

private struct StorageMapAggregate {
    var byteCount: Int64 = 0
    var fileCount = 0
    var sharedFileCount = 0
    var isPartial = false

    mutating func add(_ other: Self) {
        byteCount += other.byteCount
        fileCount += other.fileCount
        sharedFileCount += other.sharedFileCount
        isPartial = isPartial || other.isPartial
    }
}

private struct StorageMapListing {
    let names: [String]
    let hasMore: Bool
    let hadInvalidName: Bool
}

