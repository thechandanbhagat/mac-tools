import Foundation

struct StorageCleaner: Sendable {
    typealias TrashHandler = @Sendable (URL) throws -> Void
    private let trashItem: TrashHandler

    init(trashItem: @escaping TrashHandler = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) {
        self.trashItem = trashItem
    }

    /// The caller supplies only files the user explicitly reviewed and confirmed.
    /// A failed validation never falls back to deleting or resolving another path.
    func clean(
        reviewedItems: [StorageItem],
        configuration: ScanConfiguration = .standard
    ) async throws -> CleanupResult {
        let handler = trashItem
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var movedItems: [StorageItem] = []
            var failedItems: [CleanupFailure] = []
            var visited = Set<String>()
            for item in reviewedItems {
                if Task.isCancelled { break }
                guard visited.insert(item.id).inserted else { continue }
                do {
                    guard configuration.roots.contains(item.root) else {
                        throw FileSafetyError.refused("This file is not inside a folder allowed by the current scan. Scan again before cleaning.")
                    }
                    let checked = try FileSafety.checkedRoot(item.root)
                    guard checked.url.path == item.canonicalRootURL.path,
                          checked.snapshot.identity == item.rootIdentity else {
                        throw FileSafetyError.refused("The scanned folder has changed. Scan again before cleaning.")
                    }
                    try FileSafety.validatePath(item.url, inside: checked.url)
                    let values = try FileSafety.freshResourceValues(of: item.url, forKeys: [.isUbiquitousItemKey])
                    guard values.isUbiquitousItem != true else {
                        throw FileSafetyError.refused("Cloud-synced files are skipped to avoid syncing deletions to other devices.")
                    }
                    // Read uncached lstat metadata as the last check before the
                    // system Trash call. A changed or replaced file is rejected.
                    let current = try FileSafety.snapshot(of: item.url)
                    guard FileSafety.isRegularFile(current), current == item.snapshot else {
                        throw FileSafetyError.refused("This file has changed since the scan. Scan again before cleaning.")
                    }
                    if Task.isCancelled { break }
                    try handler(item.url)
                    movedItems.append(item)
                } catch {
                    failedItems.append(CleanupFailure(item: item, message: error.localizedDescription))
                }
            }
            return CleanupResult(movedItems: movedItems, failedItems: failedItems, isCancelled: Task.isCancelled)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
