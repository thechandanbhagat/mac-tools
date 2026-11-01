import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum MetadataCategory: String, CaseIterable, Identifiable, Sendable {
    case gps = "Location (GPS)"
    case exif = "Camera & EXIF"
    case document = "Document Info"
    case extendedAttributes = "Extended Attributes"

    public var id: String { rawValue }
}

public struct MetadataField: Identifiable, Equatable, Sendable {
    public let id: String
    public let category: MetadataCategory
    public let key: String
    public let value: String

    public init(category: MetadataCategory, key: String, value: String) {
        self.id = "\(category.rawValue):\(key)"
        self.category = category
        self.key = key
        self.value = value
    }
}

public enum MetadataFileKind: String, Equatable, Sendable {
    case image = "Image"
    case pdf = "PDF"
    case other = "File"
}

struct MetadataRecord: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let name: String
    let kind: MetadataFileKind
    let byteCount: Int64
    let fields: [MetadataField]
    let xattrNames: [String]
    let snapshot: FileSnapshot

    init(
        url: URL,
        name: String? = nil,
        kind: MetadataFileKind,
        byteCount: Int64,
        fields: [MetadataField],
        xattrNames: [String],
        snapshot: FileSnapshot
    ) {
        let standardized = url.standardized
        self.id = standardized.path
        self.url = standardized
        self.name = name ?? standardized.lastPathComponent
        self.kind = kind
        self.byteCount = byteCount
        self.fields = fields
        self.xattrNames = xattrNames
        self.snapshot = snapshot
    }

    var hasPrivacyMetadata: Bool {
        !fields.isEmpty || !xattrNames.isEmpty
    }
}

public struct MetadataIssue: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.id = "\(path):\(message)"
        self.path = path
        self.message = message
    }
}

struct MetadataScrubOutcome: Equatable, Sendable {
    let exportedURLs: [URL]
    let updatedRecords: [MetadataRecord]
    let issues: [MetadataIssue]
}

enum MetadataScrubber {
    static func inspect(urls: [URL]) -> (records: [MetadataRecord], issues: [MetadataIssue]) {
        var seen = Set<String>()
        var records: [MetadataRecord] = []
        var issues: [MetadataIssue] = []

        for rawURL in urls {
            let url = rawURL.standardized
            guard seen.insert(url.path).inserted else { continue }
            do {
                records.append(try inspectFile(at: url))
            } catch {
                issues.append(MetadataIssue(path: url.path, message: error.localizedDescription))
            }
        }
        return (records, issues)
    }

    static func inspectFile(at rawURL: URL) throws -> MetadataRecord {
        let url = rawURL.standardized
        let snapshot = try DuplicateFileAccess.validate(url, directory: false)

        let ext = url.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)
        let kind: MetadataFileKind
        if utType?.conforms(to: .pdf) == true || ext == "pdf" {
            kind = .pdf
        } else if utType?.conforms(to: .image) == true {
            kind = .image
        } else {
            kind = .other
        }

        var fields: [MetadataField] = []
        switch kind {
        case .image:
            fields.append(contentsOf: inspectImageMetadata(at: url))
        case .pdf:
            fields.append(contentsOf: inspectPDFMetadata(at: url))
        case .other:
            break
        }

        let xattrs = inspectExtendedAttributes(at: url)
        fields.append(contentsOf: xattrs.fields)

        return MetadataRecord(
            url: url,
            kind: kind,
            byteCount: snapshot.logicalBytes,
            fields: fields,
            xattrNames: xattrs.names,
            snapshot: snapshot
        )
    }

    static func scrubFiles(
        records: [MetadataRecord],
        outputDirectory: URL? = nil,
        stripExtendedAttributesInPlace: Bool = false
    ) -> MetadataScrubOutcome {
        var exported: [URL] = []
        var updated: [MetadataRecord] = []
        var issues: [MetadataIssue] = []

        for record in records {
            do {
                let currentSnapshot = try DuplicateFileAccess.validate(record.url, directory: false)
                guard currentSnapshot == record.snapshot else {
                    issues.append(MetadataIssue(path: record.url.path, message: "Skipped because the file changed since inspection."))
                    continue
                }

                if stripExtendedAttributesInPlace {
                    for name in record.xattrNames {
                        _ = removexattr(record.url.path, name, XATTR_NOFOLLOW)
                    }
                    updated.append(try inspectFile(at: record.url))
                } else {
                    let targetFolder = (outputDirectory ?? record.url.deletingLastPathComponent()).standardized
                    _ = try DuplicateFileAccess.validate(targetFolder, directory: true)
                    let outURL = try exportCleanCopy(of: record, into: targetFolder)
                    exported.append(outURL)
                    updated.append(try inspectFile(at: record.url))
                }
            } catch {
                issues.append(MetadataIssue(path: record.url.path, message: error.localizedDescription))
            }
        }
        return MetadataScrubOutcome(exportedURLs: exported, updatedRecords: updated, issues: issues)
    }

    private static func exportCleanCopy(of record: MetadataRecord, into folder: URL) throws -> URL {
        let baseName = record.url.deletingPathExtension().lastPathComponent
        let ext = record.url.pathExtension
        let destination = try uniqueOutputURL(folder: folder, baseName: "\(baseName)-clean", pathExtension: ext)

        switch record.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(record.url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let sourceType = CGImageSourceGetType(source) else {
                throw FileSafetyError.refused("Couldn’t decode image \(record.name).")
            }
            let data = NSMutableData()
            guard let imageDest = CGImageDestinationCreateWithData(data as CFMutableData, sourceType, 1, nil) else {
                throw FileSafetyError.refused("Couldn’t create clean image export for \(record.name).")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] ?? 1
            let cleanProps: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            CGImageDestinationAddImage(imageDest, cgImage, cleanProps as CFDictionary)
            guard CGImageDestinationFinalize(imageDest) else {
                throw FileSafetyError.refused("Couldn’t finalize clean image for \(record.name).")
            }
            try (data as Data).write(to: destination, options: .withoutOverwriting)

        case .pdf:
            guard let document = PDFDocument(url: record.url) else {
                throw FileSafetyError.refused("Couldn’t read PDF \(record.name).")
            }
            guard !document.isEncrypted else {
                throw FileSafetyError.refused("Encrypted PDFs cannot be scrubbed.")
            }
            document.documentAttributes = [:]
            guard let data = document.dataRepresentation() else {
                throw FileSafetyError.refused("Couldn’t serialize clean PDF for \(record.name).")
            }
            try data.write(to: destination, options: .withoutOverwriting)

        case .other:
            let data = try Data(contentsOf: record.url)
            try data.write(to: destination, options: .withoutOverwriting)
        }

        // Ensure extended attributes are also stripped on the exported copy
        let exportedXattrs = inspectExtendedAttributes(at: destination).names
        for name in exportedXattrs {
            _ = removexattr(destination.path, name, XATTR_NOFOLLOW)
        }
        return destination
    }

    private static func uniqueOutputURL(folder: URL, baseName: String, pathExtension: String) throws -> URL {
        for index in 1...500 {
            let suffix = index == 1 ? "" : "-\(index)"
            let fileName = pathExtension.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(pathExtension)"
            let candidate = folder.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw FileSafetyError.refused("Couldn’t find an available export filename in \(folder.lastPathComponent).")
    }

    private static func inspectImageMetadata(at url: URL) -> [MetadataField] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return []
        }
        var fields: [MetadataField] = []

        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            for key in gps.keys.sorted() {
                let value = String(describing: gps[key] ?? "")
                if !value.isEmpty {
                    fields.append(MetadataField(category: .gps, key: key, value: value))
                }
            }
        }
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            for key in exif.keys.sorted() {
                let value = String(describing: exif[key] ?? "")
                if !value.isEmpty {
                    fields.append(MetadataField(category: .exif, key: key, value: value))
                }
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for key in tiff.keys.sorted() {
                let value = String(describing: tiff[key] ?? "")
                if !value.isEmpty {
                    fields.append(MetadataField(category: .exif, key: "TIFF.\(key)", value: value))
                }
            }
        }
        if let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            for key in iptc.keys.sorted() {
                let value = String(describing: iptc[key] ?? "")
                if !value.isEmpty {
                    fields.append(MetadataField(category: .document, key: "IPTC.\(key)", value: value))
                }
            }
        }
        return fields
    }

    private static func inspectPDFMetadata(at url: URL) -> [MetadataField] {
        guard let doc = PDFDocument(url: url),
              let attrs = doc.documentAttributes else {
            return []
        }
        var fields: [MetadataField] = []
        for (rawKey, rawValue) in attrs {
            let key = String(describing: rawKey)
            let value = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value != "()" else { continue }
            fields.append(MetadataField(category: .document, key: key, value: value))
        }
        return fields.sorted { $0.key < $1.key }
    }

    private static func inspectExtendedAttributes(at url: URL) -> (names: [String], fields: [MetadataField]) {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return ([], []) }
        var nameBuffer = [CChar](repeating: 0, count: size)
        let readSize = listxattr(url.path, &nameBuffer, size, XATTR_NOFOLLOW)
        guard readSize > 0 else { return ([], []) }

        var names: [String] = []
        let ignoredKernelAttrs: Set<String> = ["com.apple.provenance", "com.apple.macl"]
        var current: [UInt8] = []
        for byte in nameBuffer.prefix(readSize) {
            if byte == 0 {
                if !current.isEmpty {
                    let name = String(decoding: current, as: UTF8.self)
                    if !ignoredKernelAttrs.contains(name) {
                        names.append(name)
                    }
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(UInt8(bitPattern: byte))
            }
        }

        var fields: [MetadataField] = []
        for name in names.sorted() {
            let valueLen = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            var display = "\(max(0, valueLen)) bytes"
            if valueLen > 0 && valueLen <= 4096 {
                var valueBuf = [UInt8](repeating: 0, count: valueLen)
                let got = getxattr(url.path, name, &valueBuf, valueLen, 0, XATTR_NOFOLLOW)
                if got > 0 {
                    let data = Data(valueBuf.prefix(got))
                    if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                        display = String(describing: plist)
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                        display = str
                    }
                }
            }
            fields.append(MetadataField(category: .extendedAttributes, key: name, value: display))
        }
        return (names.sorted(), fields)
    }
}
