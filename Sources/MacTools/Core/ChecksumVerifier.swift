import CryptoKit
import Darwin
import Foundation

public enum ChecksumAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"
    case sha1 = "SHA-1"
    case md5 = "MD5"

    public var id: String { rawValue }

    public var expectedHexLength: Int {
        switch self {
        case .sha256: 64
        case .sha512: 128
        case .sha1: 40
        case .md5: 32
        }
    }
}

public enum ChecksumComparison: Equatable, Sendable {
    case notProvided
    case matches
    case mismatch
}

public struct ChecksumRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let byteCount: Int64
    public let modifiedDate: Date
    public let digests: [ChecksumAlgorithm: String]

    public init(
        id: String? = nil,
        url: URL,
        name: String? = nil,
        byteCount: Int64,
        modifiedDate: Date,
        digests: [ChecksumAlgorithm: String]
    ) {
        let standardized = url.standardizedFileURL
        self.id = id ?? standardized.path
        self.url = standardized
        self.name = name ?? standardized.lastPathComponent
        self.byteCount = byteCount
        self.modifiedDate = modifiedDate
        self.digests = digests
    }

    public func digest(for algorithm: ChecksumAlgorithm) -> String? {
        digests[algorithm]
    }
}

public struct ChecksumIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.id = "\(path):\(message)"
        self.path = path
        self.message = message
    }
}

public struct ChecksumBatchResult: Equatable, Sendable {
    public let records: [ChecksumRecord]
    public let issues: [ChecksumIssue]

    public init(records: [ChecksumRecord], issues: [ChecksumIssue]) {
        self.records = records
        self.issues = issues
    }
}

public enum ChecksumVerifier {
    private static let chunkSize = 64 * 1024

    public static func normalizeDigest(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    public static func compare(digest: String, expected: String) -> ChecksumComparison {
        let normalizedExpected = normalizeDigest(expected)
        guard !normalizedExpected.isEmpty else { return .notProvided }
        return normalizeDigest(digest) == normalizedExpected ? .matches : .mismatch
    }

    public static func inspect(urls: [URL]) throws -> ChecksumBatchResult {
        var seen = Set<String>()
        var records: [ChecksumRecord] = []
        var issues: [ChecksumIssue] = []

        for rawURL in urls {
            try Task.checkCancellation()
            let url = rawURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            do {
                records.append(try inspectFile(at: url))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(ChecksumIssue(path: url.path, message: error.localizedDescription))
            }
        }
        return ChecksumBatchResult(records: records, issues: issues)
    }

    public static func inspectFile(at rawURL: URL) throws -> ChecksumRecord {
        try Task.checkCancellation()
        let url = rawURL.standardizedFileURL
        guard url.isFileURL else {
            throw FileSafetyError.refused("Choose a local file.")
        }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let initialSnapshot = FileSafety.snapshot(from: metadata)
        guard FileSafety.isRegularFile(initialSnapshot) else {
            throw FileSafetyError.refused("Only regular files can be hashed. Folders, packages, and symbolic links are skipped.")
        }
        guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
            throw FileSafetyError.refused("Cloud placeholder files are skipped to avoid downloading remote data.")
        }
        let values = try FileSafety.freshResourceValues(of: url, forKeys: [.isUbiquitousItemKey, .isPackageKey])
        guard values.isUbiquitousItem != true else {
            throw FileSafetyError.refused("Cloud files are skipped to avoid downloading remote data.")
        }
        guard values.isPackage != true else {
            throw FileSafetyError.refused("Packages are skipped.")
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let openedSnapshot = FileSafety.snapshot(from: openedMetadata)
        guard openedSnapshot == initialSnapshot else {
            throw FileSafetyError.refused("The file changed while opening it. Try again.")
        }

        var sha256 = SHA256()
        var sha512 = SHA512()
        var sha1 = Insecure.SHA1()
        var md5 = Insecure.MD5()

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var totalRead: Int64 = 0

        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, rawBuffer.count)
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            if readCount == 0 { break }
            totalRead += Int64(readCount)
            buffer.withUnsafeBytes { rawBuffer in
                let slice = UnsafeRawBufferPointer(rebasing: rawBuffer.prefix(readCount))
                sha256.update(bufferPointer: slice)
                sha512.update(bufferPointer: slice)
                sha1.update(bufferPointer: slice)
                md5.update(bufferPointer: slice)
            }
        }

        var afterMetadata = stat()
        guard fstat(descriptor, &afterMetadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let afterSnapshot = FileSafety.snapshot(from: afterMetadata)
        guard afterSnapshot == openedSnapshot, totalRead == openedSnapshot.logicalBytes else {
            throw FileSafetyError.refused("The file changed while computing its checksum.")
        }

        let digests: [ChecksumAlgorithm: String] = [
            .sha256: hexString(sha256.finalize()),
            .sha512: hexString(sha512.finalize()),
            .sha1: hexString(sha1.finalize()),
            .md5: hexString(md5.finalize())
        ]
        let modifiedDate = Date(
            timeIntervalSince1970: TimeInterval(openedMetadata.st_mtimespec.tv_sec)
                + TimeInterval(openedMetadata.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return ChecksumRecord(
            url: url,
            byteCount: openedSnapshot.logicalBytes,
            modifiedDate: modifiedDate,
            digests: digests
        )
    }

    private static func hexString<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
