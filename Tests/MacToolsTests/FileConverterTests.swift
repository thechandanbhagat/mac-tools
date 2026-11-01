import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import MacTools

@MainActor
final class FileConverterTests: XCTestCase {
    func testImageFormatsResizeWithoutUpscaling() throws {
        let data = try imageData(width: 120, height: 80)
        for format in ConvertedImageFormat.allCases {
            let options = FileConversionOptions(imageFormat: format, maximumDimension: 60)
            let converted = try FileConverter.convertImage(data, options: options)
            let image = try decode(converted)
            XCTAssertEqual(image.width, 60); XCTAssertEqual(image.height, 40)
        }
        let full = try decode(FileConverter.convertImage(data, options: .init(maximumDimension: 400)))
        XCTAssertEqual(full.width, 120); XCTAssertEqual(full.height, 80)
        let original = try decode(FileConverter.convertImage(data, options: .init(maximumDimension: nil)))
        XCTAssertEqual(original.width, 120)
    }
    func testJPEGTransparencyBecomesWhite() throws {
        let data = try imageData(width: 20, height: 20, transparent: true)
        let converted = try FileConverter.convertImage(data, options: .init(imageFormat: .jpeg, maximumDimension: nil))
        let image = try decode(converted)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: 5, y: 5)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.95); XCTAssertGreaterThan(color.greenComponent, 0.95); XCTAssertGreaterThan(color.blueComponent, 0.95)
    }
    func testImageOrientationIsAppliedAndMetadataRemoved() throws {
        let source = try decode(imageData(width: 120, height: 80))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6,
                                                       kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 42.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let converted = try FileConverter.convertImage(data as Data, options: .init(imageFormat: .png, maximumDimension: nil))
        let image = try decode(converted)
        XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 120)
        let output = try XCTUnwrap(CGImageSourceCreateWithData(converted as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }
    func testExportsKeepOriginalAndNeverOverwriteExistingExport() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let original = try imageData(width: 120, height: 80)
        let file = try fixture.file("photo.png", data: original)
        let input = try FileConverter.inspect(file)
        let first = await FileConverter().convert(inputs: [input], options: .init(), outputFolder: fixture.root)
        let second = await FileConverter().convert(inputs: [input], options: .init(), outputFolder: fixture.root)
        XCTAssertTrue(first.failures.isEmpty); XCTAssertTrue(second.failures.isEmpty)
        XCTAssertEqual(first.outputs.first?.url.lastPathComponent, "photo-converted.jpg")
        XCTAssertEqual(second.outputs.first?.url.lastPathComponent, "photo-converted-2.jpg")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testChangedInputIsRejectedBeforeExport() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let file = try fixture.file("photo.png", data: imageData(width: 30, height: 20))
        let input = try FileConverter.inspect(file)
        try imageData(width: 60, height: 40).write(to: file)
        let result = await FileConverter().convert(inputs: [input], options: .init(), outputFolder: fixture.root)
        XCTAssertTrue(result.outputs.isEmpty); XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].message.contains("changed"))
    }
    func testUnicodeFileNameExportsWithinFileSystemByteLimit() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let file = try fixture.file(String(repeating: "界", count: 75) + ".png", data: imageData(width: 20, height: 20))
        let result = await FileConverter().convert(inputs: [try FileConverter.inspect(file)], options: .init(), outputFolder: fixture.root)
        XCTAssertTrue(result.failures.isEmpty)
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertLessThanOrEqual(output.url.lastPathComponent.utf8.count, 255)
        XCTAssertNotNil(try decode(Data(contentsOf: output.url)))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix(".MacTools-export-") }
        XCTAssertTrue(leftovers.isEmpty)
    }
    func testLinksCloudAndPackagePathsAreRejected() throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let data = try imageData(width: 10, height: 10)
        let file = try fixture.file("photo.png", data: data)
        let linked = fixture.root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file)
        XCTAssertThrowsError(try FileConverter.inspect(linked))
        let cloud = try fixture.file("CloudStorage/Provider/photo.png", data: data)
        XCTAssertThrowsError(try FileConverter.inspect(cloud))
        let packaged = try fixture.file("Example.app/Contents/photo.png", data: data)
        XCTAssertThrowsError(try FileConverter.inspect(packaged))
    }
    func testCombineKeepsDocumentAndPageOrder() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let first = try fixture.file("first.pdf", data: pdfData(widths: [210, 220]))
        let second = try fixture.file("second.pdf", data: pdfData(widths: [310]))
        let result = await FileConverter().convert(inputs: [try FileConverter.inspect(second), try FileConverter.inspect(first)],
                                                   options: .init(mode: .combinePDF), outputFolder: fixture.root)
        XCTAssertTrue(result.failures.isEmpty)
        let output = try XCTUnwrap(result.outputs.first)
        let document = try XCTUnwrap(PDFDocument(url: output.url))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual((0..<3).map { document.page(at: $0)?.bounds(for: .mediaBox).width }, [310, 210, 220])
    }
    func testPDFCompressionProducesSmallerRasterPDFWithSamePageSize() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let data = try rasterPDF()
        let file = try fixture.file("scan.pdf", data: data)
        let result = await FileConverter().convert(inputs: [try FileConverter.inspect(file)], options: .init(mode: .compressPDF, quality: 0.3, pdfDPI: 72), outputFolder: fixture.root)
        XCTAssertTrue(result.failures.isEmpty)
        let output = try XCTUnwrap(result.outputs.first)
        XCTAssertLessThan(output.byteCount, Int64(data.count))
        let document = try XCTUnwrap(PDFDocument(url: output.url))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 400))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testConversionReportsFailuresAlongsideSuccessfulFiles() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let good = try fixture.file("good.png", data: imageData(width: 10, height: 10))
        let bad = try fixture.file("bad.png", data: Data("invalid image".utf8))
        let result = await FileConverter().convert(inputs: [try FileConverter.inspect(good), try FileConverter.inspect(bad)], options: .init(), outputFolder: fixture.root)
        XCTAssertEqual(result.outputs.count, 1); XCTAssertEqual(result.failures.count, 1); XCTAssertEqual(result.failures.first?.name, "bad.png")
    }
    func testCancelledConversionCreatesNoOutput() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let file = try fixture.file("photo.png", data: imageData(width: 10, height: 10))
        let input = try FileConverter.inspect(file)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileConverter().convert(inputs: [input], options: .init(), outputFolder: fixture.root)
        }
        let result = await task.value
        XCTAssertTrue(result.isCancelled); XCTAssertTrue(result.outputs.isEmpty)
    }
    func testSymlinkOutputDirectoryIsRefused() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let file = try fixture.file("photo.png", data: imageData(width: 10, height: 10))
        let directory = fixture.root.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("LinkedOutput")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let result = await FileConverter().convert(inputs: [try FileConverter.inspect(file)], options: .init(), outputFolder: link)
        XCTAssertTrue(result.outputs.isEmpty); XCTAssertEqual(result.failures.count, 1)
    }
    func testModelMaintainsExplicitOrderAndExportsOnlyOnConvert() async throws {
        let fixture = try ConverterFixture(); defer { fixture.remove() }
        let first = try fixture.file("first.pdf", data: pdfData(widths: [210]))
        let second = try fixture.file("second.pdf", data: pdfData(widths: [310]))
        let model = FileConverterModel(isDemo: false); defer { model.shutdown() }
        model.mode = .combinePDF; model.addFiles([first, second]); try await waitForIdle(model)
        XCTAssertEqual(model.inputs.map(\.url), [first, second]); XCTAssertTrue(model.outputs.isEmpty)
        let secondInput = try XCTUnwrap(model.inputs.last)
        model.move(secondInput, by: -1)
        XCTAssertEqual(model.inputs.map(\.url), [second, first]); XCTAssertFalse(model.canConvert)
        model.setOutputFolder(fixture.root); XCTAssertTrue(model.canConvert)
        model.convert(); try await waitForIdle(model)
        XCTAssertEqual(model.outputs.count, 1); XCTAssertTrue(model.failures.isEmpty)
    }
    func testDemoUsesOnlyDisposableFixtureFiles() async throws {
        let model = FileConverterModel(isDemo: true)
        model.loadIfNeeded()
        XCTAssertEqual(model.inputs.count, 2)
        let root = try XCTUnwrap(model.outputFolder?.deletingLastPathComponent())
        XCTAssertTrue(root.path.hasPrefix("/private/tmp/MacTools-ConverterDemo-"))
        model.convert(); try await waitForIdle(model)
        XCTAssertEqual(model.outputs.count, 2)
        model.mode = .combinePDF; XCTAssertEqual(model.inputs.count, 2)
        model.shutdown(); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func waitForIdle(_ model: FileConverterModel) async throws {
        for _ in 0..<500 { if !model.isBusy { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for conversion"); throw CancellationError()
    }
    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func imageData(width: Int, height: Int, transparent: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent { context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
    private func pdfData(widths: [CGFloat]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
        for width in widths {
            var box = CGRect(x: 0, y: 0, width: width, height: 400)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 10, y: 10, width: 20, height: 30))
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    private func rasterPDF() throws -> Data {
        var state: UInt32 = 12345
        var pixels = [UInt8](repeating: 0, count: 800 * 800 * 4)
        for index in pixels.indices {
            state = 1664525 &* state &+ 1013904223
            pixels[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 800, height: 800, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 3200,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData(); let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 400, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.draw(image, in: box); context.endPDFPage(); context.closePDF()
        return data as Data
    }
}

private struct ConverterFixture {
    let root = URL(fileURLWithPath: "/private/tmp/MacTools-ConverterTest-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ name: String, data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
