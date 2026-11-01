import Darwin
import Foundation

public enum DeveloperArtifactKind: String, CaseIterable, Identifiable, Sendable {
    case nodeModules = "node_modules"
    case swiftBuild = ".build"
    case derivedData = "DerivedData"
    case cocoaPods = "Pods"
    case rustTarget = "target"
    case gradle = ".gradle"
    case nextJS = ".next"
    case pythonVenv = ".venv"
    case pycache = "__pycache__"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nodeModules: "Node Modules"
        case .swiftBuild: "Swift Build"
        case .derivedData: "Xcode DerivedData"
        case .cocoaPods: "CocoaPods"
        case .rustTarget: "Build Target"
        case .gradle: "Gradle Cache"
        case .nextJS: "Next.js Cache"
        case .pythonVenv: "Python Venv"
        case .pycache: "Python Cache"
        }
    }

    public var directoryName: String { rawValue }

    public static func matching(directoryName: String) -> DeveloperArtifactKind? {
        Self.allCases.first { $0.directoryName == directoryName }
    }
}

struct DeveloperArtifact: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let projectName: String
    let kind: DeveloperArtifactKind
    let byteCount: Int64
    let fileCount: Int
    let modifiedDate: Date
    let snapshot: FileSnapshot
    let parentIdentity: FileIdentity

    init(
        url: URL,
        projectName: String,
        kind: DeveloperArtifactKind,
        byteCount: Int64,
        fileCount: Int,
        modifiedDate: Date,
        snapshot: FileSnapshot,
        parentIdentity: FileIdentity
    ) {
        let standardized = url.standardized
        self.id = standardized.path
        self.url = standardized
        self.projectName = projectName
        self.kind = kind
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.modifiedDate = modifiedDate
        self.snapshot = snapshot
        self.parentIdentity = parentIdentity
    }
}

struct DeveloperScanIssue: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let message: String

    init(path: String, message: String) {
        self.id = "\(path):\(message)"
        self.path = path
        self.message = message
    }
}

struct DeveloperScanReport: Equatable, Sendable {
    let rootURL: URL
    let artifacts: [DeveloperArtifact]
    let issues: [DeveloperScanIssue]
    let inspectedCount: Int

    init(
        rootURL: URL,
        artifacts: [DeveloperArtifact],
        issues: [DeveloperScanIssue],
        inspectedCount: Int
    ) {
        self.rootURL = rootURL.standardized
        self.artifacts = artifacts
        self.issues = issues
        self.inspectedCount = inspectedCount
    }

    var totalBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.byteCount }
    }
}

struct DeveloperCleanupOutcome: Equatable, Sendable {
    let trashed: [DeveloperArtifact]
    let issues: [DeveloperScanIssue]

    init(trashed: [DeveloperArtifact], issues: [DeveloperScanIssue]) {
        self.trashed = trashed
        self.issues = issues
    }

    var reclaimedBytes: Int64 {
        trashed.reduce(0) { $0 + $1.byteCount }
    }
}

enum DeveloperCleaner {
    typealias TrashHandler = (URL) throws -> Void

    static func scan(
        root rawRoot: URL,
        enabledKinds: Set<DeveloperArtifactKind> = Set(DeveloperArtifactKind.allCases),
        maxDepth: Int = 8,
        maxEntries: Int = 120_000
    ) throws -> DeveloperScanReport {
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

        var worker = DeveloperScanWorker(
            rootURL: rootURL,
            rootDevice: openedStat.st_dev,
            enabledKinds: enabledKinds,
            maxDepth: maxDepth,
            maxEntries: maxEntries
        )
        try worker.walkProjectTree(
            descriptor: rootDescriptor,
            url: rootURL,
            directoryIdentity: rootSnapshot.identity,
            depth: 0
        )
        let sorted = worker.artifacts.sorted { lhs, rhs in
            if lhs.byteCount != rhs.byteCount { return lhs.byteCount > rhs.byteCount }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }
        return DeveloperScanReport(
            rootURL: rootURL,
            artifacts: sorted,
            issues: worker.issues,
            inspectedCount: worker.inspectedCount
        )
    }

    static func moveToTrash(
        artifacts: [DeveloperArtifact],
        root rawRoot: URL,
        trashItem: TrashHandler = { url in
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        }
    ) throws -> DeveloperCleanupOutcome {
        try Task.checkCancellation()
        let rootURL = rawRoot.standardized
        _ = try DuplicateFileAccess.validate(rootURL, directory: true)
        var trashed: [DeveloperArtifact] = []
        var issues: [DeveloperScanIssue] = []

        for artifact in artifacts {
            try Task.checkCancellation()
            let itemURL = artifact.url.standardized
            guard FileSafety.isDescendant(itemURL, of: rootURL) else {
                issues.append(DeveloperScanIssue(path: itemURL.path, message: "Skipped because it is outside the scanned folder."))
                continue
            }
            guard DeveloperArtifactKind.matching(directoryName: itemURL.lastPathComponent) == artifact.kind else {
                issues.append(DeveloperScanIssue(path: itemURL.path, message: "Skipped because the directory name is not a recognized build artifact."))
                continue
            }
            do {
                let parentURL = itemURL.deletingLastPathComponent()
                let parentSnapshot = try FileSafety.snapshot(of: parentURL)
                guard FileSafety.isDirectory(parentSnapshot),
                      parentSnapshot.identity == artifact.parentIdentity else {
                    issues.append(DeveloperScanIssue(path: itemURL.path, message: "Skipped because the parent project folder changed since scanning."))
                    continue
                }
                let currentSnapshot = try FileSafety.snapshot(of: itemURL)
                guard FileSafety.isDirectory(currentSnapshot),
                      currentSnapshot == artifact.snapshot else {
                    issues.append(DeveloperScanIssue(path: itemURL.path, message: "Skipped because the folder changed since scanning. Rescan before moving it to Trash."))
                    continue
                }
                try trashItem(itemURL)
                trashed.append(artifact)
            } catch {
                issues.append(DeveloperScanIssue(path: itemURL.path, message: error.localizedDescription))
            }
        }

        return DeveloperCleanupOutcome(trashed: trashed, issues: issues)
    }
}

private struct DeveloperScanWorker {
    let rootURL: URL
    let rootDevice: dev_t
    let enabledKinds: Set<DeveloperArtifactKind>
    let maxDepth: Int
    let maxEntries: Int

    var artifacts: [DeveloperArtifact] = []
    var issues: [DeveloperScanIssue] = []
    var inspectedCount = 0
    private var visitedDirectories = Set<FileIdentity>()

    init(
        rootURL: URL,
        rootDevice: dev_t,
        enabledKinds: Set<DeveloperArtifactKind>,
        maxDepth: Int,
        maxEntries: Int
    ) {
        self.rootURL = rootURL
        self.rootDevice = rootDevice
        self.enabledKinds = enabledKinds
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    mutating func walkProjectTree(
        descriptor: Int32,
        url: URL,
        directoryIdentity: FileIdentity,
        depth: Int
    ) throws {
        try Task.checkCancellation()
        guard visitedDirectories.insert(directoryIdentity).inserted else { return }
        guard depth <= maxDepth else { return }
        guard inspectedCount < maxEntries else { return }

        let names = try listNames(descriptor: descriptor, url: url)
        for name in names {
            try Task.checkCancellation()
            guard inspectedCount < maxEntries else {
                issues.append(DeveloperScanIssue(path: rootURL.path, message: "Reached the scan item limit; some folders were skipped."))
                return
            }
            inspectedCount += 1

            var childStat = stat()
            guard fstatat(descriptor, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                continue
            }
            let childSnapshot = FileSafety.snapshot(from: childStat)
            guard FileSafety.isDirectory(childSnapshot) else { continue }
            guard childStat.st_dev == rootDevice, childStat.st_flags & UInt32(SF_DATALESS) == 0 else { continue }

            let childURL = url.appendingPathComponent(name, isDirectory: true)
            if let values = try? FileSafety.freshResourceValues(of: childURL, forKeys: [.isPackageKey, .isUbiquitousItemKey]),
               values.isPackage == true || values.isUbiquitousItem == true {
                continue
            }

            if let kind = DeveloperArtifactKind.matching(directoryName: name) {
                guard enabledKinds.contains(kind) else { continue }
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childDescriptor >= 0 else {
                    issues.append(DeveloperScanIssue(path: childURL.path, message: "Couldn’t open folder to measure size."))
                    continue
                }
                defer { close(childDescriptor) }

                var openedStat = stat()
                guard fstat(childDescriptor, &openedStat) == 0,
                      FileSafety.snapshot(from: openedStat).identity == childSnapshot.identity else {
                    continue
                }

                let measurement = try measureDirectory(descriptor: childDescriptor, url: childURL, depth: 0)
                if measurement.byteCount > 0 {
                    let modifiedDate = Date(
                        timeIntervalSince1970: TimeInterval(openedStat.st_mtimespec.tv_sec)
                            + TimeInterval(openedStat.st_mtimespec.tv_nsec) / 1_000_000_000
                    )
                    artifacts.append(
                        DeveloperArtifact(
                            url: childURL,
                            projectName: url.lastPathComponent,
                            kind: kind,
                            byteCount: measurement.byteCount,
                            fileCount: measurement.fileCount,
                            modifiedDate: modifiedDate,
                            snapshot: FileSafety.snapshot(from: openedStat),
                            parentIdentity: directoryIdentity
                        )
                    )
                }
                continue
            }

            // Skip hidden directories (other than recognized artifact folders handled above)
            if name.hasPrefix(".") { continue }

            let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard childDescriptor >= 0 else { continue }
            defer { close(childDescriptor) }

            var openedStat = stat()
            guard fstat(childDescriptor, &openedStat) == 0,
                  FileSafety.snapshot(from: openedStat).identity == childSnapshot.identity else {
                continue
            }

            try walkProjectTree(
                descriptor: childDescriptor,
                url: childURL,
                directoryIdentity: childSnapshot.identity,
                depth: depth + 1
            )
        }
    }

    private mutating func measureDirectory(
        descriptor: Int32,
        url: URL,
        depth: Int
    ) throws -> (byteCount: Int64, fileCount: Int) {
        try Task.checkCancellation()
        guard depth <= 32, inspectedCount < maxEntries else { return (0, 0) }
        let names = try listNames(descriptor: descriptor, url: url)
        var totalBytes: Int64 = 0
        var totalFiles = 0

        for name in names {
            try Task.checkCancellation()
            guard inspectedCount < maxEntries else { break }
            inspectedCount += 1

            var entryStat = stat()
            guard fstatat(descriptor, name, &entryStat, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard entryStat.st_dev == rootDevice, entryStat.st_flags & UInt32(SF_DATALESS) == 0 else { continue }

            let mode = entryStat.st_mode & mode_t(S_IFMT)
            if mode == mode_t(S_IFREG) {
                let allocated = Int64(entryStat.st_blocks) * 512
                totalBytes += max(allocated, Int64(entryStat.st_size))
                totalFiles += 1
            } else if mode == mode_t(S_IFDIR) {
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childDescriptor >= 0 else { continue }
                defer { close(childDescriptor) }
                let childURL = url.appendingPathComponent(name, isDirectory: true)
                let sub = try measureDirectory(descriptor: childDescriptor, url: childURL, depth: depth + 1)
                totalBytes += sub.byteCount
                totalFiles += sub.fileCount
            }
        }
        return (totalBytes, totalFiles)
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
