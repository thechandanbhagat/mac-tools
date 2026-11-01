import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MacTools

final class PortInspectorTests: XCTestCase {
    func testParseLsofFieldOutputExtractsTCPAndUDPListeningPorts() {
        let sample = """
        p4120
        cnode
        u501
        f22
        tIPv4
        PTCP
        n127.0.0.1:3000
        TST=LISTEN
        p5210
        cmdnsresponder
        u501
        f8
        tIPv4
        PUDP
        n*:5353
        """
        let entries = PortInspector.parseLsofFieldOutput(sample) { _ in "/usr/local/bin/node" }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.port, 3000)
        XCTAssertEqual(entries.first?.transport, .tcp)
        XCTAssertEqual(entries.first?.processName, "node")
        XCTAssertEqual(entries.first?.address, "127.0.0.1")
        XCTAssertEqual(entries.last?.port, 5353)
        XCTAssertEqual(entries.last?.transport, .udp)
    }

    func testTerminateRefusesProtectedProcesses() {
        let inspector = PortInspector()
        let rootEntry = ListeningPortItem(
            pid: 1,
            processName: "launchd",
            executablePath: "/sbin/launchd",
            userID: 0,
            transport: .tcp,
            address: "0.0.0.0",
            port: 80
        )
        XCTAssertThrowsError(try inspector.terminate(rootEntry, force: false))

        let selfEntry = ListeningPortItem(
            pid: ProcessInfo.processInfo.processIdentifier,
            processName: "MacTools",
            executablePath: nil,
            userID: getuid(),
            transport: .tcp,
            address: "127.0.0.1",
            port: 8080
        )
        XCTAssertThrowsError(try inspector.terminate(selfEntry, force: false))
    }
}

final class MetadataScrubberTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacToolsMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testInspectAndScrubImageEXIFAndExtendedAttributes() throws {
        let imageURL = root.appendingPathComponent("photo.jpg")
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() else {
            XCTFail("Could not create test image")
            return
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Could not create image destination")
            return
        }
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "TestLens 35mm"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLongitude: 122.4194
            ]
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (mutableData as Data).write(to: imageURL)

        let quarantine = Data("0081;00000000;Safari;".utf8)
        _ = quarantine.withUnsafeBytes { ptr in
            setxattr(imageURL.path, "com.apple.quarantine", ptr.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW)
        }

        let inspected = try MetadataScrubber.inspectFile(at: imageURL)
        XCTAssertTrue(inspected.fields.contains { $0.category == .gps })
        XCTAssertTrue(inspected.hasPrivacyMetadata)
        XCTAssertTrue(inspected.fields.contains { $0.category == .extendedAttributes && $0.key == "com.apple.quarantine" })

        let exportOutcome = MetadataScrubber.scrubFiles(
            records: [inspected],
            outputDirectory: root,
            stripExtendedAttributesInPlace: false
        )
        XCTAssertEqual(exportOutcome.exportedURLs.count, 1)
        let exportedURL = try XCTUnwrap(exportOutcome.exportedURLs.first)
        XCTAssertEqual(exportedURL.lastPathComponent, "photo-clean.jpg")

        let exportedRecord = try MetadataScrubber.inspectFile(at: exportedURL)
        XCTAssertFalse(exportedRecord.fields.contains { $0.category == .gps })
        XCTAssertFalse(exportedRecord.fields.contains { $0.key == (kCGImagePropertyExifLensModel as String) })
        XCTAssertTrue(exportedRecord.xattrNames.isEmpty)

        let inPlaceOutcome = MetadataScrubber.scrubFiles(
            records: [inspected],
            stripExtendedAttributesInPlace: true
        )
        XCTAssertEqual(inPlaceOutcome.updatedRecords.count, 1)
        let rechecked = try MetadataScrubber.inspectFile(at: imageURL)
        XCTAssertTrue(rechecked.xattrNames.isEmpty)
    }
}

final class LargeFilesFinderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacToolsLargeFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testScanFindsLargeFilesAndMoveToTrashRevalidatesSnapshot() throws {
        let largeArchive = root.appendingPathComponent("Archive.zip")
        let smallNote = root.appendingPathComponent("note.txt")
        try Data(repeating: 0x41, count: 1_500_000).write(to: largeArchive)
        try Data("small".utf8).write(to: smallNote)

        let report = try LargeFilesFinder.scan(root: root, minimumBytes: 1_000_000)
        XCTAssertEqual(report.items.map(\.name), ["Archive.zip"])
        XCTAssertEqual(report.items.first?.kind, .archives)

        let item = try XCTUnwrap(report.items.first)
        var trashed: [String] = []
        let outcome = try LargeFilesFinder.moveToTrash(items: [item], root: root) { url in
            trashed.append(url.path)
        }
        XCTAssertEqual(outcome.trashed.count, 1)
        XCTAssertEqual(trashed, [largeArchive.standardized.path])
    }
}

final class EmptyItemsCleanerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacToolsEmptyItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testScanFindsEmptyDirectoriesAndBrokenSymlinksAndRevalidatesBeforeTrash() throws {
        let emptyDir = root.appendingPathComponent("EmptyFolder", isDirectory: true)
        let nonEmptyDir = root.appendingPathComponent("NonEmptyFolder", isDirectory: true)
        let brokenLink = root.appendingPathComponent("BrokenLink")

        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonEmptyDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nonEmptyDir.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: brokenLink.path,
            withDestinationPath: root.appendingPathComponent("MissingTarget").path
        )

        let report = try EmptyItemsCleaner.scan(root: root)
        XCTAssertEqual(report.items.count, 2)
        XCTAssertEqual(Set(report.items.map(\.kind)), [.emptyFolder, .brokenSymlink])

        // Populate emptyDir before trashing and verify it is refused
        try Data("now non-empty".utf8).write(to: emptyDir.appendingPathComponent("new.txt"))

        var trashedPaths: [String] = []
        let outcome = try EmptyItemsCleaner.moveToTrash(items: report.items, root: root) { url in
            trashedPaths.append(url.path)
        }
        XCTAssertEqual(outcome.trashed.count, 1)
        XCTAssertEqual(trashedPaths, [brokenLink.standardized.path])
        XCTAssertEqual(outcome.issues.count, 1)
    }
}
