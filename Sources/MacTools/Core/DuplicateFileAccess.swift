import CryptoKit
import Darwin
import Foundation

/// Shared safeguards for the two tools that operate on explicitly chosen ordinary files.
enum DuplicateFileAccess {
    static func validate(_ url: URL, directory: Bool = false) throws -> FileSnapshot {
        guard url.isFileURL, url.standardized.path == url.path else {
            throw FileSafetyError.refused("Choose a local path without symbolic links.")
        }
        var initialMetadata = stat()
        guard lstat(url.path, &initialMetadata) == 0 else { throw posix(url) }
        guard initialMetadata.st_flags & UInt32(SF_DATALESS) == 0 else { throw FileSafetyError.refused("Cloud placeholders are skipped.") }
        let snapshot = FileSafety.snapshot(from: initialMetadata)
        guard directory ? FileSafety.isDirectory(snapshot) : FileSafety.isRegularFile(snapshot) else {
            throw FileSafetyError.refused("Only ordinary local \(directory ? "folders" : "files") are supported.")
        }
        var cursor = url
        while cursor.path != "/" {
            let components = cursor.pathComponents
            guard !components.contains("CloudStorage"), !components.contains("Mobile Documents"),
                  !cursor.lastPathComponent.hasSuffix(".icloud") else {
                throw FileSafetyError.refused("Cloud locations are skipped.")
            }
            var ancestorMetadata = stat()
            guard lstat(cursor.path, &ancestorMetadata) == 0 else { throw posix(cursor) }
            guard ancestorMetadata.st_flags & UInt32(SF_DATALESS) == 0 else { throw FileSafetyError.refused("Cloud placeholders are skipped.") }
            let metadata = FileSafety.snapshot(from: ancestorMetadata)
            guard !FileSafety.isSymlink(metadata) else { throw FileSafetyError.refused("Symbolic links are skipped.") }
            let values = try FileSafety.freshResourceValues(of: cursor, forKeys: [.isPackageKey, .isUbiquitousItemKey])
            guard values.isPackage != true, values.isUbiquitousItem != true else {
                throw FileSafetyError.refused("Cloud files and application or document packages are skipped.")
            }
            cursor.deleteLastPathComponent()
        }
        return snapshot
    }

    static func ancestors(of url: URL) throws -> [URL: FileIdentity] {
        var result: [URL: FileIdentity] = [:]
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            result[cursor] = try FileSafety.snapshot(of: cursor).identity
            cursor.deleteLastPathComponent()
        }
        return result
    }

    static func validateAncestors(_ identities: [URL: FileIdentity]) throws {
        for (url, identity) in identities {
            let current = try FileSafety.snapshot(of: url)
            guard FileSafety.isDirectory(current), current.identity == identity else {
                throw FileSafetyError.refused("A parent folder changed. Choose the files again.")
            }
        }
    }

    /// A data-fork hash cannot establish equivalence for resource-fork-bearing files or aliases.
    /// This restriction belongs to duplicate detection; renaming those files remains supported.
    static func validateDuplicate(_ url: URL) throws -> FileSnapshot {
        let snapshot = try validate(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posix(url) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              FileSafety.snapshot(from: metadata) == snapshot else {
            throw FileSafetyError.refused("The file changed while it was being checked. Scan again.")
        }
        try validateDuplicateContent(url, descriptor: descriptor)
        return snapshot
    }

    private static func validateDuplicateContent(_ url: URL, descriptor: Int32) throws {
        let values = try FileSafety.freshResourceValues(of: url, forKeys: [.isAliasFileKey])
        guard values.isAliasFile != true else { throw FileSafetyError.refused("Finder aliases are skipped.") }
        let resourceBytes = fgetxattr(descriptor, "com.apple.ResourceFork", nil, 0, 0, 0)
        if resourceBytes < 0 && errno != ENOATTR { throw posix(url) }
        guard resourceBytes <= 0 else {
            throw FileSafetyError.refused("Files with resource fork content are skipped.")
        }
    }

    static func digest(_ url: URL, snapshot: FileSnapshot) throws -> String {
        try Task.checkCancellation()
        guard try validate(url) == snapshot else { throw FileSafetyError.refused("The file changed. Scan again.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posix(url) }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0, FileSafety.snapshot(from: metadata) == snapshot else {
            throw FileSafetyError.refused("The file changed while it was being opened.")
        }
        try validateDuplicateContent(url, descriptor: fd)
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw posix(url)
            }
            hash.update(data: Data(buffer.prefix(count)))
        }
        guard fstat(fd, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0, FileSafety.snapshot(from: metadata) == snapshot,
              try validate(url) == snapshot else {
            throw FileSafetyError.refused("The file changed while it was being read. Scan again.")
        }
        try validateDuplicateContent(url, descriptor: fd)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func posix(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
