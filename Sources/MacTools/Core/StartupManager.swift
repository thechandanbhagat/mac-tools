import Darwin
import Foundation

enum StartupScope: String, CaseIterable, Identifiable, Sendable {
    case user = "Yours"
    case allUsers = "All users"
    case system = "System"
    var id: String { rawValue }
}

struct StartupItem: Identifiable, Equatable, Sendable {
    let url: URL
    let label: String
    let program: String?
    let scope: StartupScope
    let trigger: String
    let disabledInFile: Bool
    var id: String { url.path }
}

struct StartupIssue: Identifiable, Sendable {
    let path: String
    let message: String
    var id: String { path + message }
}

struct StartupInventory: Sendable {
    let items: [StartupItem]
    let issues: [StartupIssue]
}

struct StartupLocation: Sendable {
    let url: URL
    let scope: StartupScope
}

struct StartupManager: Sendable {
    let locations: [StartupLocation]
    let maximumEntriesPerLocation: Int
    static let maximumFileBytes = 1_048_576

    init(locations: [StartupLocation]? = nil, maximumEntriesPerLocation: Int = 1_024) {
        self.locations = locations ?? [
            StartupLocation(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), scope: .user),
            StartupLocation(url: URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .allUsers),
            StartupLocation(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .system)
        ]
        self.maximumEntriesPerLocation = max(1, maximumEntriesPerLocation)
    }

    func inventory() async throws -> StartupInventory {
        let worker = Task.detached(priority: .utility) { try scan() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private func scan() throws -> StartupInventory {
        var items: [StartupItem] = [], issues: [StartupIssue] = []
        for location in locations {
            try Task.checkCancellation()
            let descriptor = open(location.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                if errno != ENOENT { issues.append(StartupIssue(path: location.url.path, message: "Couldn’t read this location.")) }
                continue
            }
            guard let directory = fdopendir(descriptor) else {
                close(descriptor)
                issues.append(StartupIssue(path: location.url.path, message: "Couldn’t read this location."))
                continue
            }
            defer { closedir(directory) }
            var count = 0
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { issues.append(StartupIssue(path: location.url.path, message: "The location couldn’t be fully read.")) }
                    break
                }
                let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(validatingCString: $0)
                    }
                }
                guard let name else {
                    issues.append(StartupIssue(path: location.url.path, message: "A file name in this location couldn’t be represented."))
                    continue
                }
                if name == "." || name == ".." { continue }
                count += 1
                guard count <= maximumEntriesPerLocation else {
                    issues.append(StartupIssue(path: location.url.path, message: "The item limit was reached; some entries aren’t shown."))
                    break
                }
                guard name.lowercased().hasSuffix(".plist") else { continue }
                let url = location.url.appendingPathComponent(name)
                do {
                    let data = try readFile(name: name, directory: descriptor)
                    items.append(try Self.parse(data, url: url, scope: location.scope))
                } catch {
                    issues.append(StartupIssue(path: url.path, message: error.localizedDescription))
                }
            }
        }
        return StartupInventory(items: items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }, issues: issues)
    }

    static func parse(_ data: Data, url: URL, scope: StartupScope) throws -> StartupItem {
        guard data.count <= maximumFileBytes else { throw StartupReadError.oversized }
        guard let property = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = property as? [String: Any],
              let label = dictionary["Label"] as? String,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.utf8.count <= 1_024 else {
            throw StartupReadError.invalid
        }
        let direct = dictionary["Program"] as? String
        let arguments = dictionary["ProgramArguments"] as? [String]
        let program = (direct ?? arguments?.first).map { String($0.prefix(4_096)) }
        let runAtLoad = dictionary["RunAtLoad"] as? Bool == true
        let keepAlive = dictionary["KeepAlive"] as? Bool == true || dictionary["KeepAlive"] is [String: Any]
        let trigger: String
        if keepAlive { trigger = "Keep alive" }
        else if runAtLoad { trigger = scope == .system ? "At startup" : "At sign-in" }
        else if dictionary["StartInterval"] != nil || dictionary["StartCalendarInterval"] != nil { trigger = "Scheduled" }
        else if dictionary["WatchPaths"] != nil || dictionary["QueueDirectories"] != nil { trigger = "On changes" }
        else { trigger = "On demand" }
        return StartupItem(url: url, label: label, program: program, scope: scope, trigger: trigger,
                           disabledInFile: dictionary["Disabled"] as? Bool == true)
    }

    private func readFile(name: String, directory: Int32) throws -> Data {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw StartupReadError.unreadable }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw StartupReadError.unsupported }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumFileBytes else { throw StartupReadError.oversized }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let amount = read(file, &buffer, buffer.count)
            if amount < 0 {
                if errno == EINTR { continue }
                throw StartupReadError.unreadable
            }
            if amount == 0 { break }
            guard data.count + amount <= Self.maximumFileBytes else { throw StartupReadError.oversized }
            data.append(contentsOf: buffer.prefix(amount))
        }
        return data
    }
}

private enum StartupReadError: LocalizedError {
    case oversized, invalid, unreadable, unsupported
    var errorDescription: String? {
        switch self {
        case .oversized: "The file exceeds the 1 MB reading limit."
        case .invalid: "This isn’t a valid launch configuration."
        case .unreadable: "The file couldn’t be read or is a symbolic link."
        case .unsupported: "This isn’t a regular file."
        }
    }
}
