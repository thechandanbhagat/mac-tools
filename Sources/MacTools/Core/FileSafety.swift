import Darwin
import Foundation

enum FileSafetyError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason): reason
        }
    }
}

enum FileSafety {
    static func freshResourceValues(of url: URL, forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        return try freshURL.resourceValues(forKeys: keys)
    }

    static func snapshot(of url: URL) throws -> FileSnapshot {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return snapshot(from: metadata)
    }

    static func snapshot(from metadata: stat) -> FileSnapshot {
        FileSnapshot(
            identity: FileIdentity(
                device: UInt64(UInt32(bitPattern: metadata.st_dev)),
                inode: UInt64(metadata.st_ino),
                birthSeconds: Int64(metadata.st_birthtimespec.tv_sec),
                birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
            ),
            logicalBytes: max(0, Int64(metadata.st_size)),
            allocatedBytes: max(0, Int64(metadata.st_blocks) * 512),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            mode: UInt16(metadata.st_mode)
        )
    }

    static func isRegularFile(_ snapshot: FileSnapshot) -> Bool {
        snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFREG)
    }

    static func isDirectory(_ snapshot: FileSnapshot) -> Bool {
        snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFDIR)
    }

    static func isSymlink(_ snapshot: FileSnapshot) -> Bool {
        snapshot.mode & UInt16(S_IFMT) == UInt16(S_IFLNK)
    }

    static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") && childPath != rootPath
    }

    static func checkedRoot(_ root: ScanRoot) throws -> (url: URL, snapshot: FileSnapshot) {
        guard root.url.isFileURL else { throw FileSafetyError.refused("Only local folders can be scanned.") }
        let original = try snapshot(of: root.url)
        guard isDirectory(original), !isSymlink(original) else {
            throw FileSafetyError.refused("Skipped a symbolic link or a location that is not a folder.")
        }
        let canonical = root.url.resolvingSymlinksInPath().standardizedFileURL
        // A root is a chosen subfolder, never an entire volume or the user's home.
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != "/", canonical != home,
              canonical.pathComponents.count >= 3 else {
            throw FileSafetyError.refused("This location is too broad to scan safely.")
        }
        let values = try freshResourceValues(of: canonical, forKeys: [.isPackageKey, .isHiddenKey, .isUbiquitousItemKey])
        guard values.isPackage != true, values.isHidden != true else {
            throw FileSafetyError.refused("Hidden folders and application or document packages are skipped.")
        }
        guard values.isUbiquitousItem != true else {
            throw FileSafetyError.refused("Cloud-synced folders are skipped to avoid syncing deletions to other devices.")
        }
        var ancestor = canonical.deletingLastPathComponent()
        while ancestor.path != "/" {
            let ancestorValues = try freshResourceValues(of: ancestor, forKeys: [.isPackageKey, .isUbiquitousItemKey])
            guard ancestorValues.isPackage != true, ancestorValues.isUbiquitousItem != true else {
                throw FileSafetyError.refused("Folders inside application packages or cloud-synced locations are skipped.")
            }
            ancestor.deleteLastPathComponent()
        }
        return (canonical, try snapshot(of: canonical))
    }

    /// Walk from the candidate to the recorded root without following links.
    /// The check also excludes files inside hidden folders and packages.
    static func validatePath(_ url: URL, inside rootURL: URL) throws {
        guard url.isFileURL, isDescendant(url, of: rootURL),
              url.standardizedFileURL == url,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
            throw FileSafetyError.refused("The file is outside the scanned folder or its path now contains a symbolic link.")
        }
        var cursor = url
        while cursor.path != rootURL.path {
            let current = try snapshot(of: cursor)
            guard !isSymlink(current) else {
                throw FileSafetyError.refused("Symbolic links are never cleaned.")
            }
            let values = try freshResourceValues(of: cursor, forKeys: [.isPackageKey, .isHiddenKey, .isUbiquitousItemKey])
            guard values.isHidden != true, !cursor.lastPathComponent.hasPrefix("."), values.isPackage != true,
                  values.isUbiquitousItem != true else {
                throw FileSafetyError.refused("Hidden files, cloud-synced locations, and application or document packages are skipped.")
            }
            cursor.deleteLastPathComponent()
        }
    }
}
