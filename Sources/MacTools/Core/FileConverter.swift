import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum FileConversionMode: String, CaseIterable, Identifiable, Sendable {
    case images = "Images", combinePDF = "Combine PDFs", compressPDF = "Compress PDFs"
    var id: String { rawValue }
}

enum ConvertedImageFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG", png = "PNG", tiff = "TIFF"
    var id: String { rawValue }
    var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .tiff: .tiff } }
    var fileExtension: String { switch self { case .jpeg: "jpg"; case .png: "png"; case .tiff: "tiff" } }
}

struct FileConversionOptions: Sendable {
    var mode: FileConversionMode = .images
    var imageFormat: ConvertedImageFormat = .jpeg
    var maximumDimension: Int? = 2560
    var quality: Double = 0.8
    var pdfDPI: Int = 144
}

struct FileConversionInput: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let snapshot: FileSnapshot
    var name: String { url.lastPathComponent }
    var byteCount: Int64 { snapshot.logicalBytes }
}

struct FileConversionOutput: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let byteCount: Int64
    let originalBytes: Int64
}

struct FileConversionFailure: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let message: String
}

struct FileConversionResult: Sendable {
    var outputs: [FileConversionOutput] = []
    var failures: [FileConversionFailure] = []
    var isCancelled = false
}

struct FileConversionProgress: Sendable {
    let completed: Int
    let total: Int
    let name: String
}

enum FileConverterError: LocalizedError {
    case refused(String)
    var errorDescription: String? { switch self { case .refused(let text): text } }
}

struct FileConverter: Sendable {
    static let maximumInputBytes: Int64 = 256 * 1024 * 1024

    static func inspect(_ url: URL) throws -> FileConversionInput {
        try validatePath(url, directory: false)
        let snapshot = try FileSafety.snapshot(of: url)
        guard snapshot.logicalBytes > 0, snapshot.logicalBytes <= maximumInputBytes else {
            throw FileConverterError.refused("Choose a file smaller than 256 MB that is not empty.")
        }
        return FileConversionInput(url: url, snapshot: snapshot)
    }

    func convert(inputs: [FileConversionInput], options: FileConversionOptions, outputFolder: URL,
                 progress: @escaping @Sendable (FileConversionProgress) async -> Void = { _ in }) async -> FileConversionResult {
        let worker = Task.detached(priority: .userInitiated) {
            await Self.run(inputs: inputs, options: options, outputFolder: outputFolder, progress: progress)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func run(inputs: [FileConversionInput], options: FileConversionOptions, outputFolder: URL,
                            progress: @escaping @Sendable (FileConversionProgress) async -> Void) async -> FileConversionResult {
        var result = FileConversionResult()
        do {
            guard !inputs.isEmpty, inputs.count <= 100, inputs.reduce(Int64(0), { $0 + $1.byteCount }) <= 512 * 1024 * 1024,
                  options.quality >= 0.1, options.quality <= 1,
                  options.maximumDimension == nil || (1...8192).contains(options.maximumDimension!),
                  (72...300).contains(options.pdfDPI) else {
                throw FileConverterError.refused("Choose up to 100 files totaling at most 512 MB and valid conversion settings.")
            }
            try validatePath(outputFolder, directory: true)
            let folderSnapshot = try FileSafety.snapshot(of: outputFolder)
            let descriptor = open(outputFolder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw posixError(outputFolder.path) }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  FileSafety.snapshot(from: metadata).identity == folderSnapshot.identity else {
                throw FileConverterError.refused("The output folder changed. Choose it again.")
            }
            try Task.checkCancellation()
            if options.mode == .combinePDF {
                let document = PDFDocument()
                var pageCount = 0
                for (index, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    await progress(.init(completed: index, total: inputs.count, name: input.name))
                    let source = try pdf(from: read(input))
                    guard pageCount + source.pageCount <= 1000 else { throw FileConverterError.refused("Combine up to 1,000 PDF pages at a time.") }
                    for number in 0..<source.pageCount {
                        try Task.checkCancellation()
                        guard let page = source.page(at: number)?.copy() as? PDFPage else { throw FileConverterError.refused("Couldn’t read a PDF page in \(input.name).") }
                        document.insert(page, at: pageCount)
                        pageCount += 1
                    }
                }
                guard let data = document.dataRepresentation(), !data.isEmpty else { throw FileConverterError.refused("Couldn’t create the combined PDF.") }
                try Task.checkCancellation()
                let url = try write(data, stem: "Combined", extension: "pdf", folder: outputFolder, descriptor: descriptor)
                result.outputs.append(.init(url: url, byteCount: Int64(data.count), originalBytes: inputs.reduce(0) { $0 + $1.byteCount }))
                await progress(.init(completed: inputs.count, total: inputs.count, name: url.lastPathComponent))
            } else {
                for (index, input) in inputs.enumerated() {
                    try Task.checkCancellation()
                    await progress(.init(completed: index, total: inputs.count, name: input.name))
                    do {
                        let inputData = try read(input)
                        let outputData: Data
                        let suffix: String
                        if options.mode == .images {
                            outputData = try convertImage(inputData, options: options)
                            suffix = options.imageFormat.fileExtension
                        } else {
                            outputData = try compressPDF(inputData, options: options)
                            suffix = "pdf"
                        }
                        try Task.checkCancellation()
                        let stem = input.url.deletingPathExtension().lastPathComponent + (options.mode == .compressPDF ? "-compressed" : "-converted")
                        let url = try write(outputData, stem: stem, extension: suffix, folder: outputFolder, descriptor: descriptor)
                        result.outputs.append(.init(url: url, byteCount: Int64(outputData.count), originalBytes: input.byteCount))
                    } catch is CancellationError { throw CancellationError() }
                    catch { result.failures.append(.init(name: input.name, message: error.localizedDescription)) }
                    await progress(.init(completed: index + 1, total: inputs.count, name: input.name))
                }
            }
        } catch is CancellationError { result.isCancelled = true }
        catch { result.failures.append(.init(name: "Conversion", message: error.localizedDescription)) }
        return result
    }

    static func convertImage(_ data: Data, options: FileConversionOptions) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 40_000_000 / height else {
            throw FileConverterError.refused("Choose a single-frame image under 40 megapixels. Animated and multipage images are skipped.")
        }
        let dimension = min(options.maximumDimension ?? max(width, height), max(width, height))
        guard dimension <= 16_384,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw FileConverterError.refused("Couldn’t decode this image.") }
        try Task.checkCancellation()
        let image: CGImage
        if options.imageFormat == .jpeg {
            guard let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw FileConverterError.refused("Couldn’t allocate image memory.")
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            guard let flattened = context.makeImage() else { throw FileConverterError.refused("Couldn’t create the JPEG image.") }
            image = flattened
        } else { image = thumbnail }
        return try encode(image, type: options.imageFormat.type, quality: options.quality)
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw FileConverterError.refused("This image format is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileConverterError.refused("Couldn’t encode the image.") }
        return output as Data
    }

    private static func pdf(from data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), !document.isLocked, !document.isEncrypted,
              document.pageCount > 0, document.pageCount <= 1000 else {
            throw FileConverterError.refused("Choose an unencrypted PDF with 1–1,000 pages.")
        }
        return document
    }

    private static func compressPDF(_ data: Data, options: FileConversionOptions) throws -> Data {
        let document = try pdf(from: data)
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw FileConverterError.refused("Couldn’t create a PDF.")
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let reference = page.pageRef else { throw FileConverterError.refused("Couldn’t read PDF page \(index + 1).") }
            let original = reference.getBoxRect(.mediaBox)
            let rotated = abs(reference.rotationAngle) % 180 == 90
            let size = CGSize(width: rotated ? original.height : original.width, height: rotated ? original.width : original.height)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw FileConverterError.refused("This PDF contains an invalid page size.") }
            let scale = CGFloat(options.pdfDPI) / 72
            let pixelWidth = ceil(size.width * scale), pixelHeight = ceil(size.height * scale)
            guard pixelWidth <= 16_384, pixelHeight <= 16_384, pixelWidth * pixelHeight <= 40_000_000,
                  let bitmap = CGContext(data: nil, width: Int(pixelWidth), height: Int(pixelHeight), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw FileConverterError.refused("A PDF page is too large at this resolution. Try a lower resolution.")
            }
            let rectangle = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(rectangle)
            bitmap.concatenate(reference.getDrawingTransform(.mediaBox, rect: rectangle, rotate: 0, preserveAspectRatio: true))
            bitmap.drawPDFPage(reference)
            guard let image = bitmap.makeImage() else { throw FileConverterError.refused("Couldn’t render PDF page \(index + 1).") }
            let jpeg = try encode(image, type: .jpeg, quality: options.quality)
            guard let provider = CGDataProvider(data: jpeg as CFData),
                  let compressed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw FileConverterError.refused("Couldn’t compress PDF page \(index + 1).")
            }
            var mediaBox = CGRect(origin: .zero, size: size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.draw(compressed, in: mediaBox)
            context.endPDFPage()
            guard output.length <= 512 * 1024 * 1024 else { throw FileConverterError.refused("The converted PDF is too large. Try a lower resolution.") }
        }
        context.closePDF()
        return output as Data
    }

    private static func validatePath(_ url: URL, directory: Bool) throws {
        guard url.isFileURL, url.standardized.path == url.path else {
            throw FileConverterError.refused("Choose a local file or folder without symbolic links.")
        }
        var cursor = url
        while cursor.path != "/" {
            var metadata = stat()
            guard lstat(cursor.path, &metadata) == 0 else { throw posixError(cursor.path) }
            guard metadata.st_flags & UInt32(SF_DATALESS) == 0 else {
                throw FileConverterError.refused("Cloud placeholders are skipped. Choose a local copy.")
            }
            let snapshot = FileSafety.snapshot(from: metadata)
            let values = try FileSafety.freshResourceValues(of: cursor, forKeys: [.isPackageKey, .isUbiquitousItemKey])
            guard !FileSafety.isSymlink(snapshot), values.isPackage != true, values.isUbiquitousItem != true,
                  cursor.lastPathComponent != "CloudStorage", cursor.lastPathComponent != "Mobile Documents",
                  !cursor.lastPathComponent.hasSuffix(".icloud") else {
                throw FileConverterError.refused("Cloud files, symbolic links, and package contents are skipped. Choose a local copy.")
            }
            if cursor == url {
                guard directory ? FileSafety.isDirectory(snapshot) : FileSafety.isRegularFile(snapshot) else {
                    throw FileConverterError.refused(directory ? "Choose an output folder." : "Choose an ordinary local file.")
                }
            } else if !FileSafety.isDirectory(snapshot) { throw FileConverterError.refused("The file path changed. Choose it again.") }
            cursor.deleteLastPathComponent()
        }
    }

    private static func read(_ input: FileConversionInput) throws -> Data {
        try validatePath(input.url, directory: false)
        let descriptor = open(input.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError(input.url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              FileSafety.snapshot(from: metadata) == input.snapshot else {
            throw FileConverterError.refused("This file changed after selection. Add it again.")
        }
        guard let data = try handle.read(upToCount: Int(input.snapshot.logicalBytes) + 1), Int64(data.count) == input.snapshot.logicalBytes,
              fstat(descriptor, &metadata) == 0, metadata.st_flags & UInt32(SF_DATALESS) == 0,
              FileSafety.snapshot(from: metadata) == input.snapshot else {
            throw FileConverterError.refused("This file changed while being read. Add it again.")
        }
        return data
    }

    private static func write(_ data: Data, stem: String, extension suffix: String, folder: URL, descriptor: Int32) throws -> URL {
        // Stage in an owned hidden file, then publish atomically without replacing anything.
        // Interruption cannot leave a partially written file under the final export name.
        var safeStem = ""
        for character in stem.replacingOccurrences(of: "/", with: "-") {
            guard safeStem.utf8.count + String(character).utf8.count <= 200 else { break }
            safeStem.append(character)
        }
        if safeStem.isEmpty { safeStem = "Converted" }
        let temporaryName = ".MacTools-export-\(UUID().uuidString).tmp"
        let output = openat(descriptor, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw posixError(folder.path) }
        defer { unlinkat(descriptor, temporaryName, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        for attempt in 0..<10_000 {
            try Task.checkCancellation()
            let name = "\(safeStem)\(attempt == 0 ? "" : "-\(attempt + 1)").\(suffix)"
            if renameatx_np(descriptor, temporaryName, descriptor, name, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST { continue }
                throw posixError(folder.appendingPathComponent(name).path)
            }
            return folder.appendingPathComponent(name)
        }
        throw FileConverterError.refused("Too many exports share this name. Choose another folder.")
    }

    private static func posixError(_ path: String) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
