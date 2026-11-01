import XCTest
@testable import MacTools

final class ChecksumVerifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacToolsChecksumTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testInspectFileComputesAllDigestsAndMatchesExpected() throws {
        let fileURL = root.appendingPathComponent("sample.txt")
        try Data("hello world".utf8).write(to: fileURL)

        let record = try ChecksumVerifier.inspectFile(at: fileURL)
        XCTAssertEqual(record.name, "sample.txt")
        XCTAssertEqual(record.byteCount, 11)
        XCTAssertEqual(
            record.digest(for: .sha256),
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        )
        XCTAssertEqual(
            record.digest(for: .sha1),
            "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed"
        )
        XCTAssertEqual(
            record.digest(for: .md5),
            "5eb63bbbe01eeed093cb22bb8f5acdc3"
        )
        XCTAssertEqual(
            ChecksumVerifier.compare(
                digest: record.digest(for: .sha256) ?? "",
                expected: "  0xB94D27B9934D3E08A52E52D7DA7DABFAC484EFE37A5380EE9088F7ACE2EFCDE9 \n"
            ),
            .matches
        )
        XCTAssertEqual(
            ChecksumVerifier.compare(digest: record.digest(for: .sha256) ?? "", expected: "deadbeef"),
            .mismatch
        )
    }

    func testSymlinksAndDirectoriesAreSkippedAsIssues() throws {
        let regularURL = root.appendingPathComponent("valid.bin")
        let folderURL = root.appendingPathComponent("subfolder", isDirectory: true)
        let symlinkURL = root.appendingPathComponent("link.bin")

        try Data([1, 2, 3, 4]).write(to: regularURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: regularURL)

        let batch = try ChecksumVerifier.inspect(urls: [regularURL, folderURL, symlinkURL])
        XCTAssertEqual(batch.records.map(\.name), ["valid.bin"])
        XCTAssertEqual(batch.issues.count, 2)
    }

    @MainActor
    func testModelAutoSelectsAlgorithmFromExpectedChecksumLength() async throws {
        let fileURL = root.appendingPathComponent("payload.txt")
        try Data("hello world".utf8).write(to: fileURL)

        let model = ChecksumVerifierModel(isDemo: false)
        model.addFiles([fileURL])
        for _ in 0..<50 {
            if !model.isComputing && !model.records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.records.count, 1)
        model.expectedChecksum = "5eb63bbbe01eeed093cb22bb8f5acdc3"
        XCTAssertEqual(model.algorithm, .md5)
        XCTAssertEqual(model.matchingCount, 1)
    }
}

final class DeveloperCleanerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacToolsDevCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testScanFindsRecognizedBuildDirectoriesAndSkipsSymlinks() throws {
        let nodeModules = root.appendingPathComponent("web-client/node_modules/pkg", isDirectory: true)
        let swiftBuild = root.appendingPathComponent("swift-tool/.build/debug", isDirectory: true)
        let normalSrc = root.appendingPathComponent("swift-tool/Sources", isDirectory: true)
        let symlinkBuild = root.appendingPathComponent("linked-project/node_modules")

        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: swiftBuild, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalSrc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlinkBuild.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(repeating: 0xAA, count: 64_000).write(to: nodeModules.appendingPathComponent("index.js"))
        try Data(repeating: 0xBB, count: 32_000).write(to: swiftBuild.appendingPathComponent("tool.o"))
        try Data(repeating: 0xCC, count: 16_000).write(to: normalSrc.appendingPathComponent("main.swift"))
        try FileManager.default.createSymbolicLink(at: symlinkBuild, withDestinationURL: nodeModules.deletingLastPathComponent())

        let report = try DeveloperCleaner.scan(root: root)
        XCTAssertEqual(report.artifacts.count, 2)
        XCTAssertEqual(Set(report.artifacts.map(\.kind)), [.nodeModules, .swiftBuild])
        XCTAssertEqual(Set(report.artifacts.map(\.projectName)), ["web-client", "swift-tool"])
    }

    func testMoveToTrashRevalidatesSnapshotAndSkipsChangedDirectories() throws {
        let nodeModules = root.appendingPathComponent("app/node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        let fileURL = nodeModules.appendingPathComponent("bundle.js")
        try Data(repeating: 0x55, count: 16_384).write(to: fileURL)

        let report = try DeveloperCleaner.scan(root: root)
        XCTAssertEqual(report.artifacts.count, 1)
        let artifact = try XCTUnwrap(report.artifacts.first)

        var trashedPaths: [String] = []
        let outcome = try DeveloperCleaner.moveToTrash(artifacts: [artifact], root: root) { url in
            trashedPaths.append(url.path)
        }
        XCTAssertEqual(outcome.trashed.count, 1)
        XCTAssertEqual(trashedPaths, [nodeModules.standardized.path])

        // Replace directory with a new inode and verify moveToTrash refuses it
        try FileManager.default.removeItem(at: nodeModules)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data(repeating: 0x55, count: 16_384).write(to: fileURL)

        let secondOutcome = try DeveloperCleaner.moveToTrash(artifacts: [artifact], root: root) { _ in
            XCTFail("Changed directory must not be moved to Trash without rescanning")
        }
        XCTAssertTrue(secondOutcome.trashed.isEmpty)
        XCTAssertEqual(secondOutcome.issues.count, 1)
    }
}
