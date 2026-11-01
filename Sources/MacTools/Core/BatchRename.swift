import Darwin
import Foundation

struct BatchRenameOptions: Equatable, Sendable {
    var find = ""
    var replacement = ""
    var prefix = ""
    var suffix = ""
    var numbering = false
    var startNumber = 1
    var includeDate = false
    var preserveExtension = true
}

struct BatchRenameEntry: Identifiable, Sendable {
    var id: String { source.path }
    let source: URL
    let destination: URL
    let snapshot: FileSnapshot
    let ancestors: [URL: FileIdentity]
    var changes: Bool { source.path != destination.path }
}

struct BatchRenamePlan: Identifiable, Sendable {
    let id = UUID()
    let entries: [BatchRenameEntry]
    var changes: [BatchRenameEntry] { entries.filter(\.changes) }
}

struct BatchRenameReceipt: Sendable {
    let undoPlan: BatchRenamePlan
}

struct BatchRenamer: Sendable {
    var renameItem: @Sendable (URL, URL) throws -> Void = { source, destination in
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw DuplicateFileAccess.posix(source) }
    }
    func preview(files: [URL], options: BatchRenameOptions, date: Date = Date()) throws -> BatchRenamePlan {
        guard !files.isEmpty else { return BatchRenamePlan(entries: []) }
        guard files.count <= 5_000 else { throw FileSafetyError.refused("Choose up to 5,000 files at a time.") }
        guard options.startNumber >= 0, options.startNumber <= Int.max - files.count else {
            throw FileSafetyError.refused("Choose a valid starting number.")
        }
        guard Set(files.map(\.path)).count == files.count else { throw FileSafetyError.refused("A file was selected more than once.") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let dateText = formatter.string(from: date)
        let sorted = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var identities: Set<FileIdentity> = []
        let entries = try sorted.enumerated().map { index, source in
            try Task.checkCancellation()
            let snapshot = try DuplicateFileAccess.validate(source)
            guard identities.insert(snapshot.identity).inserted else {
                throw FileSafetyError.refused("Choose only one hard link to each file in a batch. Linked names share the same file metadata.")
            }
            let ext = options.preserveExtension ? source.pathExtension : ""
            var name = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            if !options.find.isEmpty { name = name.replacingOccurrences(of: options.find, with: options.replacement) }
            name = options.prefix + name + options.suffix
            if options.includeDate { name += "_" + dateText }
            if options.numbering { name += "_" + String(options.startNumber + index) }
            if !ext.isEmpty { name += "." + ext }
            try validateName(name)
            return BatchRenameEntry(source: source, destination: source.deletingLastPathComponent().appendingPathComponent(name),
                                    snapshot: snapshot, ancestors: try DuplicateFileAccess.ancestors(of: source))
        }
        let plan = BatchRenamePlan(entries: entries)
        try validate(plan)
        return plan
    }

    func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 255 else {
            throw FileSafetyError.refused("Names must be visible, 1–255 bytes long, and contain no slash, colon, or null character.")
        }
    }

    func validate(_ plan: BatchRenamePlan) throws {
        var destinationKeys: Set<String> = []
        var directoryNames: [URL: [String: [String]]] = [:]
        var caseSensitivity: [URL: Bool] = [:]
        let sourcePaths = Set(plan.entries.map { $0.source.path })
        for entry in plan.entries {
            try Task.checkCancellation()
            try validateName(entry.destination.lastPathComponent)
            guard entry.source.deletingLastPathComponent() == entry.destination.deletingLastPathComponent() else {
                throw FileSafetyError.refused("Files must stay in their original folders.")
            }
            try DuplicateFileAccess.validateAncestors(entry.ancestors)
            guard try DuplicateFileAccess.validate(entry.source) == entry.snapshot else {
                throw FileSafetyError.refused("“\(entry.source.lastPathComponent)” changed. Choose the files again.")
            }
            let parent = entry.source.deletingLastPathComponent()
            if caseSensitivity[parent] == nil {
                let values = try FileSafety.freshResourceValues(of: parent, forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                caseSensitivity[parent] = values.volumeSupportsCaseSensitiveNames == true
            }
            let caseSensitive = caseSensitivity[parent] == true
            func key(_ value: String) -> String {
                let normalized = value.precomposedStringWithCanonicalMapping
                return caseSensitive ? normalized : normalized.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            let destinationKey = parent.path + "/" + key(entry.destination.lastPathComponent)
            guard destinationKeys.insert(destinationKey).inserted else {
                throw FileSafetyError.refused("Two files would have the same name. Change the naming options.")
            }
            if directoryNames[parent] == nil {
                directoryNames[parent] = Dictionary(grouping: try FileManager.default.contentsOfDirectory(atPath: parent.path), by: key)
            }
            for sibling in directoryNames[parent]?[key(entry.destination.lastPathComponent)] ?? [] {
                let siblingPath = parent.appendingPathComponent(sibling).path
                guard sourcePaths.contains(siblingPath) else {
                    throw FileSafetyError.refused("“\(entry.destination.lastPathComponent)” already exists. No files were renamed.")
                }
            }
        }
    }

    func apply(_ plan: BatchRenamePlan) async throws -> BatchRenameReceipt {
        // Once a confirmed transaction starts, finish or roll it back rather than stopping halfway.
        try await Task.detached(priority: .userInitiated) { try applySynchronously(plan) }.value
    }

    private func applySynchronously(_ plan: BatchRenamePlan) throws -> BatchRenameReceipt {
        try validate(plan)
        let changes = plan.changes
        guard !changes.isEmpty else { throw FileSafetyError.refused("There are no name changes to apply.") }
        struct Staged {
            let entry: BatchRenameEntry
            let temporary: URL
            var current: URL
        }
        var staged: [Staged] = []
        do {
            for entry in changes {
                try DuplicateFileAccess.validateAncestors(entry.ancestors)
                guard try DuplicateFileAccess.validate(entry.source) == entry.snapshot else {
                    throw FileSafetyError.refused("A selected file changed. No further files were renamed.")
                }
                let temporary = entry.source.deletingLastPathComponent().appendingPathComponent(".MacTools-Rename-\(UUID().uuidString)")
                try renameItem(entry.source, temporary)
                staged.append(Staged(entry: entry, temporary: temporary, current: temporary))
            }
            for index in staged.indices {
                let item = staged[index]
                try DuplicateFileAccess.validateAncestors(item.entry.ancestors)
                guard try FileSafety.snapshot(of: item.current).identity == item.entry.snapshot.identity else {
                    throw FileSafetyError.refused("A staged file changed. Rename stopped.")
                }
                try renameItem(item.current, item.entry.destination)
                staged[index].current = item.entry.destination
            }
            let undoEntries = try changes.map { entry in
                BatchRenameEntry(source: entry.destination, destination: entry.source,
                                 snapshot: try DuplicateFileAccess.validate(entry.destination), ancestors: entry.ancestors)
            }
            return BatchRenameReceipt(undoPlan: BatchRenamePlan(entries: undoEntries))
        } catch {
            let failure = error.localizedDescription
            var recovery: [String] = []
            // Return completed destinations to their reserved temporary names before restoring sources,
            // so cycles and case-only renames roll back without overwriting anything.
            for index in staged.indices where staged[index].current != staged[index].temporary {
                do {
                    let item = staged[index]
                    try DuplicateFileAccess.validateAncestors(item.entry.ancestors)
                    guard try FileSafety.snapshot(of: item.current).identity == item.entry.snapshot.identity else { throw FileSafetyError.refused("File identity changed.") }
                    try renameItem(item.current, item.temporary)
                    staged[index].current = item.temporary
                } catch {
                    // A direct restore may still succeed; only report files that remain unrestored below.
                }
            }
            for item in staged {
                do {
                    try DuplicateFileAccess.validateAncestors(item.entry.ancestors)
                    guard try FileSafety.snapshot(of: item.current).identity == item.entry.snapshot.identity else { throw FileSafetyError.refused("File identity changed.") }
                    try renameItem(item.current, item.entry.source)
                } catch { recovery.append(item.current.path) }
            }
            if !recovery.isEmpty {
                throw FileSafetyError.refused("\(failure) Some files need recovery from these locations:\n\(Set(recovery).sorted().joined(separator: "\n"))")
            }
            throw FileSafetyError.refused("\(failure) All name changes were rolled back.")
        }
    }

}
