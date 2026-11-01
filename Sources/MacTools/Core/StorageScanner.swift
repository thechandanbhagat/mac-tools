import Foundation

struct StorageScanner: Sendable {
    /// Enumerates metadata on a utility task. File contents are never opened.
    func scan(
        configuration: ScanConfiguration = .standard,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanResult {
        let worker = Task.detached(priority: .utility) {
            try Self.scanFiles(configuration: configuration, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func scanFiles(
        configuration: ScanConfiguration,
        progress: @Sendable (ScanProgress) -> Void
    ) throws -> ScanResult {
        try Task.checkCancellation()
        let fileManager = FileManager()
        var items: [StorageItem] = []
        var issues: [ScanIssue] = []
        var inspectedCount = 0
        var discoveredBytes: Int64 = 0
        var visitedPaths = Set<String>()
        var visitedFiles = Set<FileIdentity>()
        var truncatedCategories = Set<CleanupCategory>()
        var categoryEntries: [CleanupCategory: Int] = [:]
        var categoryItems: [CleanupCategory: Int] = [:]
        var lastProgress = Date.distantPast
        let keys: Set<URLResourceKey> = [.isHiddenKey, .isPackageKey, .isUbiquitousItemKey]

        // Reserve a fair share for every enabled category. One busy cache folder
        // must not prevent Downloads or large files from being inspected. Multiple
        // roots of one category share that category's allowance; the shares sum to
        // the configured total limits, including when those limits do not divide
        // evenly. Unused shares remain unused rather than starving later roots.
        let categories = CleanupCategory.allCases.filter { category in
            configuration.roots.contains { $0.category == category }
        }
        let categoryCount = max(1, categories.count)
        let entryBudgets = Dictionary(uniqueKeysWithValues: categories.enumerated().map { index, category in
            (category, configuration.maximumEntries / categoryCount + (index < configuration.maximumEntries % categoryCount ? 1 : 0))
        })
        let itemBudgets = Dictionary(uniqueKeysWithValues: categories.enumerated().map { index, category in
            (category, configuration.maximumItems / categoryCount + (index < configuration.maximumItems % categoryCount ? 1 : 0))
        })

        // Specific categories win over a broad large-file root, independent of
        // caller order. Deduplication prevents counting overlapping roots twice.
        let roots = configuration.roots.sorted {
            if ($0.category == .largeFiles) != ($1.category == .largeFiles) {
                return $0.category != .largeFiles
            }
            return $0.url.path.count > $1.url.path.count
        }

        for root in roots {
            try Task.checkCancellation()
            if truncatedCategories.contains(root.category) { continue }
            let checked: (url: URL, snapshot: FileSnapshot)
            do {
                checked = try FileSafety.checkedRoot(root)
            } catch {
                issues.append(ScanIssue(path: root.url.path, message: error.localizedDescription))
                continue
            }
            var directories = [checked.url]
            var skippedCloudFiles = 0

            while let directory = directories.popLast() {
                try Task.checkCancellation()
                if truncatedCategories.contains(root.category) { break }
                let children: [URL]
                do {
                    if directory != checked.url {
                        try FileSafety.validatePath(directory, inside: checked.url)
                    }
                    children = try fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    issues.append(ScanIssue(path: directory.path, message: error.localizedDescription))
                    continue
                }

                for child in children {
                    try Task.checkCancellation()
                    guard categoryEntries[root.category, default: 0] < entryBudgets[root.category, default: 0],
                          categoryItems[root.category, default: 0] < itemBudgets[root.category, default: 0] else {
                        truncatedCategories.insert(root.category)
                        break
                    }
                    inspectedCount += 1
                    categoryEntries[root.category, default: 0] += 1
                    let url = child.standardizedFileURL
                    guard visitedPaths.insert(url.path).inserted else { continue }
                    do {
                        let snapshot = try FileSafety.snapshot(of: url)
                        guard !FileSafety.isSymlink(snapshot) else { continue }
                        let values = try url.resourceValues(forKeys: keys)
                        guard values.isHidden != true,
                              !url.lastPathComponent.hasPrefix("."),
                              values.isPackage != true else { continue }
                        if values.isUbiquitousItem == true {
                            skippedCloudFiles += 1
                            continue
                        }
                        if FileSafety.isDirectory(snapshot) {
                            // Directory paths are checked again before enumeration.
                            directories.append(url)
                            continue
                        }
                        guard FileSafety.isRegularFile(snapshot),
                              snapshot.logicalBytes > 0 else { continue }
                        if root.category == .largeFiles,
                           snapshot.logicalBytes < configuration.largeFileThresholdBytes { continue }
                        try FileSafety.validatePath(url, inside: checked.url)
                        guard visitedFiles.insert(snapshot.identity).inserted else { continue }
                        items.append(StorageItem(
                            url: url,
                            category: root.category,
                            byteCount: snapshot.allocatedBytes,
                            logicalByteCount: snapshot.logicalBytes,
                            modifiedAt: snapshot.modifiedAt,
                            root: root,
                            canonicalRootURL: checked.url,
                            rootIdentity: checked.snapshot.identity,
                            snapshot: snapshot
                        ))
                        categoryItems[root.category, default: 0] += 1
                        discoveredBytes += snapshot.allocatedBytes
                    } catch {
                        issues.append(ScanIssue(path: url.path, message: error.localizedDescription))
                    }
                    if Date().timeIntervalSince(lastProgress) >= 0.08 {
                        progress(ScanProgress(inspectedCount: inspectedCount, discoveredBytes: discoveredBytes, currentPath: url.path))
                        lastProgress = Date()
                    }
                }
            }
            if skippedCloudFiles > 0 {
                issues.append(ScanIssue(path: checked.url.path, message: "Skipped \(skippedCloudFiles) cloud-synced locations to avoid syncing deletions to other devices."))
            }
        }
        try Task.checkCancellation()
        for category in categories where truncatedCategories.contains(category) {
            let allowance = "\(itemBudgets[category, default: 0].formatted()) files or \(entryBudgets[category, default: 0].formatted()) inspected entries"
            let followUp = categories.count > 1 ? " Other categories continued scanning. Scan this category on its own for a larger allowance." : ""
            issues.append(ScanIssue(
                path: category.title,
                message: "\(category.title) reached its scan allowance (\(allowance)); these results are partial.\(followUp)"
            ))
        }
        progress(ScanProgress(inspectedCount: inspectedCount, discoveredBytes: discoveredBytes, currentPath: "Scan complete"))
        return ScanResult(
            items: items.sorted {
                if $0.byteCount == $1.byteCount { return $0.path < $1.path }
                return $0.byteCount > $1.byteCount
            },
            issues: issues,
            inspectedCount: inspectedCount,
            reachedLimit: !truncatedCategories.isEmpty
        )
    }
}
