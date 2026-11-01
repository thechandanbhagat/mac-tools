import Foundation

struct DuplicateFile: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let snapshot: FileSnapshot
    let ancestors: [URL: FileIdentity]
    var name: String { url.lastPathComponent }
}

struct DuplicateGroup: Identifiable, Sendable {
    var id: String { digest }
    let digest: String
    let files: [DuplicateFile]
    var byteCount: Int64 { files.first?.snapshot.logicalBytes ?? 0 }
}

struct DuplicateScanResult: Sendable {
    let groups: [DuplicateGroup]
    let issues: [ScanIssue]
    let inspectedCount: Int
}

struct DuplicateTrashRequest: Identifiable, Sendable {
    let id = UUID()
    let groups: [DuplicateGroup]
    let selectedIDs: Set<String>
    var files: [DuplicateFile] { groups.flatMap(\.files).filter { selectedIDs.contains($0.id) } }
    var byteCount: Int64 { files.reduce(0) { $0 + $1.snapshot.allocatedBytes } }
}

struct DuplicateTrashResult: Sendable {
    let movedIDs: Set<String>
    let failures: [ScanIssue]
}

struct DuplicateFinder: Sendable {
    var maximumEntries = 100_000
    var trashItem: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func scan(root: URL) async throws -> DuplicateScanResult {
        let worker = Task.detached(priority: .utility) { try scanSynchronously(root: root) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func scanSynchronously(root: URL) throws -> DuplicateScanResult {
        try Task.checkCancellation()
        let rootSnapshot = try DuplicateFileAccess.validate(root, directory: true)
        var issues: [ScanIssue] = []
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isUbiquitousItemKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                issues.append(ScanIssue(path: url.path, message: error.localizedDescription)); return true
            }) else { throw FileSafetyError.refused("This folder couldn’t be read.") }
        var files: [DuplicateFile] = []
        var identities: Set<FileIdentity> = []
        var inspected = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            inspected += 1
            if inspected > maximumEntries {
                issues.append(ScanIssue(path: root.path, message: "Scan stopped at \(maximumEntries) entries. Choose a smaller folder to scan the rest.")); break
            }
            do {
                guard try FileSafety.snapshot(of: root).identity == rootSnapshot.identity else {
                    throw FileSafetyError.refused("The chosen folder changed. Scan again.")
                }
                let snapshot = try FileSafety.snapshot(of: url)
                guard snapshot.identity.device == rootSnapshot.identity.device else { enumerator.skipDescendants(); continue }
                if FileSafety.isDirectory(snapshot) {
                    do { _ = try DuplicateFileAccess.validate(url, directory: true) }
                    catch { enumerator.skipDescendants(); issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) }
                    continue
                }
                guard FileSafety.isRegularFile(snapshot) else { continue }
                _ = try DuplicateFileAccess.validateDuplicate(url)
                guard identities.insert(snapshot.identity).inserted else { continue }
                files.append(DuplicateFile(url: url, snapshot: snapshot, ancestors: try DuplicateFileAccess.ancestors(of: url)))
            } catch { issues.append(ScanIssue(path: url.path, message: error.localizedDescription)) }
        }
        var groups: [DuplicateGroup] = []
        for bucket in Dictionary(grouping: files, by: { $0.snapshot.logicalBytes }).values where bucket.count > 1 {
            var hashes: [String: [DuplicateFile]] = [:]
            for file in bucket {
                try Task.checkCancellation()
                do {
                    try DuplicateFileAccess.validateAncestors(file.ancestors)
                    let digest = try DuplicateFileAccess.digest(file.url, snapshot: file.snapshot)
                    hashes[digest, default: []].append(file)
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(ScanIssue(path: file.url.path, message: error.localizedDescription)) }
            }
            for (digest, matches) in hashes where matches.count > 1 {
                groups.append(DuplicateGroup(digest: digest, files: matches.sorted { $0.url.path < $1.url.path }))
            }
        }
        groups.sort { $0.byteCount == $1.byteCount ? $0.id < $1.id : $0.byteCount > $1.byteCount }
        return DuplicateScanResult(groups: groups, issues: issues, inspectedCount: min(inspected, maximumEntries))
    }

    func prepare(groups: [DuplicateGroup], selectedIDs: Set<String>) throws -> DuplicateTrashRequest {
        guard !selectedIDs.isEmpty else { throw FileSafetyError.refused("Select a duplicate to remove.") }
        let allIDs = Set(groups.flatMap(\.files).map(\.id))
        guard selectedIDs.isSubset(of: allIDs) else { throw FileSafetyError.refused("The selection is out of date. Scan again.") }
        for group in groups {
            guard group.files.contains(where: { !selectedIDs.contains($0.id) }) else {
                throw FileSafetyError.refused("Keep at least one copy of every file.")
            }
        }
        return DuplicateTrashRequest(groups: groups.filter { $0.files.contains { selectedIDs.contains($0.id) } }, selectedIDs: selectedIDs)
    }

    func moveToTrash(_ request: DuplicateTrashRequest) async -> DuplicateTrashResult {
        let worker = Task.detached(priority: .userInitiated) {
            var moved: Set<String> = []
            var failures: [ScanIssue] = []
            // Rehash the entire affected group before any of its selected files move.
            groupLoop: for group in request.groups {
                do {
                    try Task.checkCancellation()
                    guard let keeper = group.files.first(where: { !request.selectedIDs.contains($0.id) }) else {
                        throw FileSafetyError.refused("Keep at least one copy of every file.")
                    }
                    for file in group.files {
                        try DuplicateFileAccess.validateAncestors(file.ancestors)
                        guard try DuplicateFileAccess.digest(file.url, snapshot: file.snapshot) == group.digest else {
                            throw FileSafetyError.refused("A duplicate changed. Scan again.")
                        }
                    }
                    for file in group.files where request.selectedIDs.contains(file.id) {
                        try Task.checkCancellation()
                        try DuplicateFileAccess.validateAncestors(keeper.ancestors)
                        guard try DuplicateFileAccess.validateDuplicate(keeper.url) == keeper.snapshot else {
                            throw FileSafetyError.refused("The copy to keep changed. Scan again.")
                        }
                        try DuplicateFileAccess.validateAncestors(file.ancestors)
                        guard try DuplicateFileAccess.validateDuplicate(file.url) == file.snapshot else {
                            throw FileSafetyError.refused("A selected file changed. Scan again.")
                        }
                        // Native Trash is path based; validation is repeated immediately before the move.
                        try trashItem(file.url)
                        moved.insert(file.id)
                    }
                } catch is CancellationError {
                    failures.append(ScanIssue(path: group.files.first?.url.path ?? "", message: "Cancelled. Remaining files were left in place.")); break groupLoop
                } catch { failures.append(ScanIssue(path: group.files.first?.url.path ?? "", message: error.localizedDescription)) }
            }
            return DuplicateTrashResult(movedIDs: moved, failures: failures)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
