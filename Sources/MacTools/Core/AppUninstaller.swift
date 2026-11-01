import AppKit
import Darwin
import Foundation

struct AppUninstallerConfiguration: Sendable {
    var applicationRoots: [URL]
    var libraryURL: URL
    var ownApplicationURL: URL?
    var maximumDiscoveryDepth: Int
    var maximumEntries: Int
    var maximumDepth: Int

    init(
        applicationRoots: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)],
        libraryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true),
        ownApplicationURL: URL? = Bundle.main.bundleURL,
        maximumDiscoveryDepth: Int = 3, maximumEntries: Int = 100_000, maximumDepth: Int = 64
    ) {
        self.applicationRoots = applicationRoots.map(\.standardized)
        self.libraryURL = libraryURL.standardized
        self.ownApplicationURL = ownApplicationURL?.standardized
        self.maximumDiscoveryDepth = max(0, min(8, maximumDiscoveryDepth))
        self.maximumEntries = max(1, maximumEntries)
        self.maximumDepth = max(1, min(128, maximumDepth))
    }

    static let standard = AppUninstallerConfiguration()
}

struct UninstallApplication: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    fileprivate let identity: FileIdentity
    fileprivate let metadataSnapshot: FileSnapshot
    fileprivate let configuration: AppUninstallerConfiguration
}

struct AppUninstallerInventory: Sendable {
    let applications: [UninstallApplication]
    let issues: [ScanIssue]
}

struct UninstallItem: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let byteCount: Int64
    let isPartial: Bool
    fileprivate let manifest: UninstallManifest
}

struct AppUninstallerInspection: Sendable {
    let application: UninstallApplication
    let appItem: UninstallItem
    let relatedItems: [UninstallItem]
    let issues: [ScanIssue]
    let isRunning: Bool
}

/// An exact, immutable set of items to present before the user confirms Trash.
struct AppUninstallerRequest: Identifiable, Sendable {
    var id: String { application.id }
    let application: UninstallApplication
    let items: [UninstallItem]
    var byteCount: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    fileprivate init(application: UninstallApplication, items: [UninstallItem]) {
        self.application = application
        self.items = items
    }
}

struct UninstallFailure: Identifiable, Sendable {
    var id: String { item.id }
    let item: UninstallItem
    let message: String
}

struct AppUninstallerResult: Sendable {
    let movedItems: [UninstallItem]
    let failures: [UninstallFailure]
    let isCancelled: Bool
    var movedBytes: Int64 { movedItems.reduce(0) { $0 + $1.byteCount } }
}

struct AppUninstaller: Sendable {
    typealias TrashHandler = @Sendable (URL) throws -> Void
    typealias RunningCheck = @Sendable (URL, String?) async -> Bool
    let configuration: AppUninstallerConfiguration
    private let trashItem: TrashHandler
    private let isRunning: RunningCheck

    init(
        configuration: AppUninstallerConfiguration = .standard,
        trashItem: @escaping TrashHandler = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        isRunning: @escaping RunningCheck = { url, identifier in
            await MainActor.run {
                NSWorkspace.shared.runningApplications.contains { app in
                    app.bundleURL?.standardized.path == url.path || (identifier != nil && app.bundleIdentifier == identifier)
                }
            }
        }
    ) {
        self.configuration = configuration
        self.trashItem = trashItem
        self.isRunning = isRunning
    }

    func inventory() async throws -> AppUninstallerInventory {
        let configuration = configuration
        return try await Self.work {
            var discovery = UninstallDiscovery(configuration: configuration)
            return try discovery.run()
        }
    }

    func inspect(application: UninstallApplication) async throws -> AppUninstallerInspection {
        let configuration = configuration
        let contents = try await Self.work {
            guard configuration.applicationRoots.contains(where: { FileSafety.isDescendant(application.url, of: $0) }),
                  application.url.pathExtension.lowercased() == "app",
                  application.url.path != configuration.ownApplicationURL?.path,
                  try FileSafety.snapshot(of: application.url).identity == application.identity,
                  try FileSafety.snapshot(of: application.url.appendingPathComponent("Contents/Info.plist")) == application.metadataSnapshot else {
                throw FileSafetyError.refused("This app changed. Refresh the app list before continuing.")
            }
            let (appItem, appIssues) = try UninstallTree.inspect(application.url, name: application.name, configuration: configuration)
            var related: [UninstallItem] = []
            var issues = appIssues
            if let identifier = application.bundleIdentifier, Self.validIdentifier(identifier) {
                let locations = [
                    "Caches/\(identifier)", "Preferences/\(identifier).plist", "Application Support/\(identifier)",
                    "Saved Application State/\(identifier).savedState", "Logs/\(identifier)",
                    "WebKit/\(identifier)", "HTTPStorages/\(identifier)"
                ]
                for location in locations {
                    try Task.checkCancellation()
                    let url = configuration.libraryURL.appendingPathComponent(location)
                    do {
                        _ = try FileSafety.snapshot(of: url)
                        let (item, itemIssues) = try UninstallTree.inspect(url, name: url.lastPathComponent, configuration: configuration)
                        related.append(item)
                        issues.append(contentsOf: itemIssues)
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { continue }
                    catch { issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) }
                }
            }
            guard appItem.manifest.entries[application.url.path]?.identity == application.identity,
                  try FileSafety.snapshot(of: application.url.appendingPathComponent("Contents/Info.plist")) == application.metadataSnapshot else {
                throw FileSafetyError.refused("This app changed while it was inspected. Refresh the app list before continuing.")
            }
            return (appItem, related, issues)
        }
        try Task.checkCancellation()
        let running = await isRunning(application.url, application.bundleIdentifier)
        try Task.checkCancellation()
        return AppUninstallerInspection(application: application, appItem: contents.0, relatedItems: contents.1, issues: contents.2, isRunning: running)
    }

    func prepare(inspection: AppUninstallerInspection, selectedRelatedIDs: Set<String>) throws -> AppUninstallerRequest {
        guard !inspection.isRunning else { throw FileSafetyError.refused("Quit \(inspection.application.name) before moving it to Trash.") }
        guard Set(inspection.relatedItems.map(\.id)).isSuperset(of: selectedRelatedIDs) else {
            throw FileSafetyError.refused("The selected files are not part of this app review.")
        }
        let items = [inspection.appItem] + inspection.relatedItems.filter { selectedRelatedIDs.contains($0.id) }
        guard !items.contains(where: \.isPartial) else {
            throw FileSafetyError.refused("Some selected items could not be fully inspected. Refresh the app before continuing.")
        }
        return AppUninstallerRequest(application: inspection.application, items: items)
    }

    /// Invoke only after confirming the request. App removal must succeed before
    /// optional related data is touched. No permanent deletion or elevation.
    func moveToTrash(request: AppUninstallerRequest) async -> AppUninstallerResult {
        guard !Task.isCancelled else { return AppUninstallerResult(movedItems: [], failures: [], isCancelled: true) }
        var moved: [UninstallItem] = []
        var failures: [UninstallFailure] = []
        guard let appItem = request.items.first else { return AppUninstallerResult(movedItems: [], failures: [], isCancelled: false) }
        do {
            guard !(await isRunning(request.application.url, request.application.bundleIdentifier)) else {
                throw FileSafetyError.refused("Quit \(request.application.name) before moving it to Trash.")
            }
        } catch is CancellationError {
            return AppUninstallerResult(movedItems: [], failures: [], isCancelled: true)
        } catch {
            return AppUninstallerResult(movedItems: [], failures: [UninstallFailure(item: appItem, message: error.localizedDescription)], isCancelled: false)
        }
        // Check the entire review before the first move, then each item again
        // immediately before its own Trash operation.
        for item in request.items {
            do { try await Self.work { try UninstallTree.validate(item, configuration: request.application.configuration) } }
            catch is CancellationError { return AppUninstallerResult(movedItems: [], failures: [], isCancelled: true) }
            catch { return AppUninstallerResult(movedItems: [], failures: [UninstallFailure(item: item, message: error.localizedDescription)], isCancelled: false) }
        }
        for item in request.items {
            if Task.isCancelled { break }
            do {
                guard !(await isRunning(request.application.url, request.application.bundleIdentifier)) else {
                    throw FileSafetyError.refused("The app is running. Quit it before continuing.")
                }
                let handler = trashItem
                try await Self.work {
                    try UninstallTree.validate(item, configuration: request.application.configuration)
                    try Task.checkCancellation()
                    // FileManager's path-based Trash API leaves a narrow race
                    // after validation; it has no descriptor-based equivalent.
                    try handler(item.url)
                }
                moved.append(item)
            } catch is CancellationError { break }
            catch {
                failures.append(UninstallFailure(item: item, message: error.localizedDescription))
                if item.id == appItem.id { break }
            }
        }
        return AppUninstallerResult(movedItems: moved, failures: failures, isCancelled: Task.isCancelled)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.contains(".") && !value.hasPrefix(".") && !value.contains("..") &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }
    }

    private static func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

private struct UninstallDiscovery {
    let configuration: AppUninstallerConfiguration
    var apps: [UninstallApplication] = []
    var issues: [ScanIssue] = []
    var visited = Set<String>()
    var entries = 0

    mutating func run() throws -> AppUninstallerInventory {
        for root in configuration.applicationRoots {
            try Task.checkCancellation()
            do {
                let opened = try UninstallPath.open(root)
                defer { close(opened.descriptor) }
                guard FileSafety.isDirectory(opened.snapshot), !root.path.hasPrefix("/System/") && root.path != "/System" else { continue }
                try walk(opened.descriptor, url: root, depth: 0)
            } catch is CancellationError { throw CancellationError() }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { continue }
            catch { issues.append(ScanIssue(path: root.path, message: error.localizedDescription)) }
        }
        return AppUninstallerInventory(applications: apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issues: issues)
    }

    mutating func walk(_ descriptor: Int32, url: URL, depth: Int) throws {
        let names = try UninstallPath.names(descriptor, url: url, remaining: min(10_000, configuration.maximumEntries) - entries)
        entries += names.count
        for name in names {
            try Task.checkCancellation()
            let child = url.appendingPathComponent(name)
            do {
                let metadata = try UninstallPath.metadata(descriptor, name: name, url: child)
                guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), !name.hasPrefix(".") else { continue }
                try UninstallPath.checkLocation(child, metadata: metadata)
                guard child.path != configuration.ownApplicationURL?.path, visited.insert(child.path).inserted else { continue }
                let next = try UninstallPath.openChildDirectory(descriptor, name: name, url: child, expected: metadata)
                defer { close(next) }
                if child.pathExtension.lowercased() == "app" {
                    let appInfo = try UninstallPath.appInfo(next, url: child)
                    let info = appInfo.info
                    let displayName = (info["CFBundleDisplayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = (displayName?.isEmpty == false ? displayName : info["CFBundleName"] as? String) ?? child.deletingPathExtension().lastPathComponent
                    apps.append(UninstallApplication(url: child, name: name, bundleIdentifier: info["CFBundleIdentifier"] as? String,
                        version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String,
                        identity: FileSafety.snapshot(from: metadata).identity, metadataSnapshot: appInfo.snapshot, configuration: configuration))
                } else if depth < configuration.maximumDiscoveryDepth,
                          try FileSafety.freshResourceValues(of: child, forKeys: [.isPackageKey]).isPackage != true {
                    try walk(next, url: child, depth: depth + 1)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append(ScanIssue(path: child.path, message: error.localizedDescription)) }
        }
    }
}

private struct UninstallManifest: Sendable, Equatable {
    let ancestors: [String: FileIdentity]
    let entries: [String: FileSnapshot]
}

private struct UninstallTree {
    let configuration: AppUninstallerConfiguration
    var entries: [String: FileSnapshot] = [:]
    var counted = Set<FileIdentity>()
    var bytes: Int64 = 0
    var issues: [ScanIssue] = []
    var count = 0
    var rootDevice: UInt64 = 0

    static func inspect(_ url: URL, name: String, configuration: AppUninstallerConfiguration) throws -> (UninstallItem, [ScanIssue]) {
        let opened = try UninstallPath.open(url)
        defer { close(opened.descriptor) }
        var tree = UninstallTree(configuration: configuration, rootDevice: opened.snapshot.identity.device)
        tree.entries[url.path] = opened.snapshot
        if FileSafety.isDirectory(opened.snapshot) {
            try tree.walk(opened.descriptor, url: url, depth: 0)
        } else if FileSafety.isRegularFile(opened.snapshot) { tree.bytes = opened.snapshot.allocatedBytes }
        else { throw FileSafetyError.refused("Symbolic links and special files cannot be uninstalled.") }
        for (path, identity) in opened.ancestors {
            let fresh = try FileSafety.snapshot(of: URL(fileURLWithPath: path, isDirectory: true))
            guard FileSafety.isDirectory(fresh), fresh.identity == identity else {
                throw FileSafetyError.refused("This item's path changed. Refresh before continuing.")
            }
        }
        let fresh = try FileSafety.snapshot(of: url)
        guard fresh == opened.snapshot else { throw FileSafetyError.refused("This item changed while it was inspected. Refresh before continuing.") }
        let manifest = UninstallManifest(ancestors: opened.ancestors, entries: tree.entries)
        return (UninstallItem(url: url, name: name, byteCount: tree.bytes, isPartial: !tree.issues.isEmpty, manifest: manifest), tree.issues)
    }

    static func validate(_ item: UninstallItem, configuration: AppUninstallerConfiguration) throws {
        try Task.checkCancellation()
        let (fresh, _) = try inspect(item.url, name: item.name, configuration: configuration)
        guard !item.isPartial, !fresh.isPartial, fresh.manifest == item.manifest else {
            throw FileSafetyError.refused("“\(item.name)” changed since review. Refresh the app before continuing.")
        }
    }

    mutating func walk(_ descriptor: Int32, url: URL, depth: Int) throws {
        do {
            let names = try UninstallPath.names(descriptor, url: url, remaining: configuration.maximumEntries - count)
            count += names.count
            guard names.isEmpty || depth < configuration.maximumDepth else { throw FileSafetyError.refused("This item exceeds the folder-depth limit; its size is partial.") }
            for name in names {
                try Task.checkCancellation()
                let child = url.appendingPathComponent(name)
                do {
                    let metadata = try UninstallPath.metadata(descriptor, name: name, url: child)
                    let snapshot = FileSafety.snapshot(from: metadata)
                    entries[child.path] = snapshot
                    guard snapshot.identity.device == rootDevice else { throw FileSafetyError.refused("An item on another volume was skipped; its size is partial.") }
                    // Framework links are part of the bundle, but their targets
                    // must never be followed, sized, or independently removed.
                    if FileSafety.isSymlink(snapshot) { continue }
                    try UninstallPath.checkLocation(child, metadata: metadata)
                    if FileSafety.isRegularFile(snapshot) {
                        if counted.insert(snapshot.identity).inserted { bytes += snapshot.allocatedBytes }
                    } else if FileSafety.isDirectory(snapshot) {
                        let next = try UninstallPath.openChildDirectory(descriptor, name: name, url: child, expected: metadata)
                        defer { close(next) }
                        try walk(next, url: child, depth: depth + 1)
                    } else { throw FileSafetyError.refused("A special file was skipped; this item could not be fully inspected.") }
                } catch is CancellationError { throw CancellationError() }
                catch { if issues.count < 100 { issues.append(ScanIssue(path: child.path, message: error.localizedDescription)) } }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { if issues.count < 100 { issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) } }
    }
}

private enum UninstallPath {
    struct Opened {
        let descriptor: Int32
        let snapshot: FileSnapshot
        let ancestors: [String: FileIdentity]
    }

    static func open(_ url: URL) throws -> Opened {
        try Task.checkCancellation()
        guard url.isFileURL, url.path == url.standardized.path, url.path != "/", !url.path.hasPrefix("/System/"), url.path != "/System" else {
            throw FileSafetyError.refused("Only local user-installed apps and their related files can be uninstalled.")
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(url) }
        var ancestors: [String: FileIdentity] = ["/": try FileSafety.snapshot(of: URL(fileURLWithPath: "/")).identity]
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        do {
            let components = Array(url.pathComponents.dropFirst())
            for (index, component) in components.enumerated() {
                try Task.checkCancellation()
                cursor.appendPathComponent(component)
                let metadata = try descriptor >= 0
                    ? self.metadata(descriptor, name: component, url: cursor)
                    : self.lstatMetadata(cursor)
                let snapshot = FileSafety.snapshot(from: metadata)
                let final = index == components.count - 1
                guard FileSafety.isDirectory(snapshot) || (final && FileSafety.isRegularFile(snapshot)) else {
                    throw FileSafetyError.refused("This item's path contains a symbolic link or a special file.")
                }
                try checkLocation(cursor, metadata: metadata)
                if !final, try FileSafety.freshResourceValues(of: cursor, forKeys: [.isPackageKey]).isPackage == true {
                    throw FileSafetyError.refused("Items inside another app or document package cannot be uninstalled.")
                }
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (FileSafety.isDirectory(snapshot) ? O_DIRECTORY : O_NONBLOCK)
                let next = descriptor >= 0
                    ? openat(descriptor, component, flags)
                    : Darwin.open(cursor.path, flags)
                if next < 0 {
                    if !final && (errno == EPERM || errno == EACCES) {
                        if descriptor >= 0 {
                            close(descriptor)
                            descriptor = -1
                        }
                        ancestors[cursor.path] = snapshot.identity
                        continue
                    }
                    throw posixError(cursor)
                }
                var opened = stat()
                guard fstat(next, &opened) == 0, FileSafety.snapshot(from: opened) == snapshot else {
                    close(next)
                    throw FileSafetyError.refused("This item's path changed. Refresh before continuing.")
                }
                if descriptor >= 0 { close(descriptor) }
                descriptor = next
                if final { return Opened(descriptor: descriptor, snapshot: snapshot, ancestors: ancestors) }
                ancestors[cursor.path] = snapshot.identity
            }
            throw FileSafetyError.refused("This location cannot be uninstalled.")
        } catch {
            if descriptor >= 0 { close(descriptor) }
            throw error
        }
    }

    static func lstatMetadata(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw posixError(url) }
        return metadata
    }

    static func checkLocation(_ url: URL, metadata: stat) throws {
        let components = url.pathComponents
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0,
              !zip(components, components.dropFirst()).contains(where: { $0.0 == "Library" && ($0.1 == "CloudStorage" || $0.1 == "Mobile Documents") }),
              try FileSafety.freshResourceValues(of: url, forKeys: [.isUbiquitousItemKey]).isUbiquitousItem != true else {
            throw FileSafetyError.refused("Cloud locations and placeholders are excluded.")
        }
    }

    static func metadata(_ descriptor: Int32, name: String, url: URL) throws -> stat {
        var metadata = stat()
        guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(url) }
        return metadata
    }

    static func openChildDirectory(_ descriptor: Int32, name: String, url: URL, expected: stat) throws -> Int32 {
        let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw posixError(url) }
        var opened = stat()
        guard fstat(next, &opened) == 0, FileSafety.snapshot(from: expected).identity == FileSafety.snapshot(from: opened).identity else {
            close(next)
            throw FileSafetyError.refused("This folder changed during inspection.")
        }
        return next
    }

    static func names(_ descriptor: Int32, url: URL, remaining: Int) throws -> [String] {
        guard remaining > 0 else { throw FileSafetyError.refused("The scan reached its entry limit; sizes are partial.") }
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw posixError(url) }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw posixError(url) }
        defer { closedir(directory) }
        var names: [String] = []
        while names.count < remaining {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError(url) }
                return names.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw FileSafetyError.refused("A file name could not be represented; this item could not be fully inspected.") }
            if name != "." && name != ".." { names.append(name) }
        }
        throw FileSafetyError.refused("The scan reached its entry limit; sizes are partial.")
    }

    static func appInfo(_ descriptor: Int32, url: URL) throws -> (info: [String: Any], snapshot: FileSnapshot) {
        let contentsURL = url.appendingPathComponent("Contents")
        let contentsMetadata = try metadata(descriptor, name: "Contents", url: contentsURL)
        try checkLocation(contentsURL, metadata: contentsMetadata)
        let contents = try openChildDirectory(descriptor, name: "Contents", url: contentsURL, expected: contentsMetadata)
        defer { close(contents) }
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let infoMetadata = try metadata(contents, name: "Info.plist", url: infoURL)
        guard FileSafety.isRegularFile(FileSafety.snapshot(from: infoMetadata)), infoMetadata.st_size <= 1_048_576 else {
            throw FileSafetyError.refused("The app's Info.plist could not be read safely.")
        }
        try checkLocation(infoURL, metadata: infoMetadata)
        let file = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixError(infoURL) }
        defer { close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0, FileSafety.snapshot(from: opened) == FileSafety.snapshot(from: infoMetadata) else {
            throw FileSafetyError.refused("The app's metadata changed during discovery.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 1_048_576 {
            try Task.checkCancellation()
            let count = read(file, &buffer, buffer.count)
            guard count >= 0 else { throw posixError(infoURL) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var afterRead = stat()
        guard fstat(file, &afterRead) == 0, FileSafety.snapshot(from: afterRead) == FileSafety.snapshot(from: infoMetadata) else {
            throw FileSafetyError.refused("The app's metadata changed during discovery.")
        }
        guard data.count <= 1_048_576, let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FileSafetyError.refused("The app's Info.plist is invalid.")
        }
        return (info, FileSafety.snapshot(from: infoMetadata))
    }

    static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
