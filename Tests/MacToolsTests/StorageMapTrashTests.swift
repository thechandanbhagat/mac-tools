import Foundation
import Darwin
import XCTest
@testable import MacTools

@MainActor
final class StorageMapTrashTests: XCTestCase {
    func testScannedFileCanBePreparedAndPassedToTrashHandler() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[file.path])
        let request = try StorageMapTrash.prepare(node: node, in: result)
        let calls = TrashCalls()

        XCTAssertEqual(node.snapshot, try FileSafety.snapshot(of: file))
        XCTAssertEqual(request.url.path, file.path)
        XCTAssertEqual(request.name, "ordinary.bin")
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: file).allocatedBytes)
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFileChangedBeforeConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[file.path])
        try Data(repeating: 3, count: 16_384).write(to: file)
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
    }

    func testFileChangedAfterConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try Data(repeating: 4, count: 16_384).write(to: file)
        await assertNoTrash(request)
    }

    func testSameLengthContentChangeIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try Data(repeating: 2, count: 8_192).write(to: file)
        await assertNoTrash(request)
    }

    func testReplacedFileIsRefusedEvenWithSameContents() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try FileManager.default.moveItem(at: file, to: fixture.url("original.bin"))
        _ = try fixture.file("parent/scan/ordinary.bin")
        await assertNoTrash(request)
    }

    func testFileReplacedBySymbolicLinkIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let outside = try fixture.file("outside.bin")
        let request = try await fixture.request(for: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await assertNoTrash(request)
        XCTAssertEqual(try Data(contentsOf: outside).count, 8_192)
    }

    func testRootReplacedAfterConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try FileManager.default.moveItem(at: fixture.scanRoot, to: fixture.url("old-scan"))
        _ = try fixture.file("parent/scan/ordinary.bin")
        await assertNoTrash(request)
    }

    func testAncestorReplacedWhileRootAndFileKeepIdentityIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try FileManager.default.moveItem(at: fixture.url("parent"), to: fixture.url("old-parent"))
        try FileManager.default.createDirectory(at: fixture.url("parent"), withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: fixture.url("old-parent/scan"), to: fixture.scanRoot)
        await assertNoTrash(request)
    }

    func testAncestorReplacedBySymbolicLinkIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        try FileManager.default.moveItem(at: fixture.url("parent"), to: fixture.url("old-parent"))
        try FileManager.default.createSymbolicLink(at: fixture.url("parent"), withDestinationURL: fixture.url("old-parent"))
        await assertNoTrash(request)
    }

    func testRootReplacedBeforePreparationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[file.path])
        try FileManager.default.moveItem(at: fixture.scanRoot, to: fixture.url("old-scan"))
        _ = try fixture.file("parent/scan/ordinary.bin")
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
    }

    func testDisplayedRootPackagesAndUnscannedFilesAreRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/folder/file.bin")
        _ = try fixture.file("parent/scan/Example.app/Contents/program")
        let outside = try fixture.file("outside.bin")
        let result = try await fixture.scan()
        for path in [fixture.scanRoot.path, fixture.url("parent/scan/Example.app").path] {
            let node = try XCTUnwrap(result.nodes[path])
            XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
        }
        let unscanned = StorageMapNode(id: outside.path, url: outside, name: "outside.bin", isDirectory: false,
                                      isPackage: false, byteCount: 8_192, fileCount: 1, childIDs: [], isPartial: false,
                                      snapshot: try FileSafety.snapshot(of: outside))
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: unscanned, in: result))
    }

    func testNestedFileMustBeScannedAsCurrentFolderBeforeTrash() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/ordinary.bin")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[file.path])
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
        let current = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: file.deletingLastPathComponent()))
        XCTAssertNoThrow(try StorageMapTrash.prepare(node: XCTUnwrap(current.nodes[file.path]), in: current))
    }

    func testFilesWithinPackageAncestorAreRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("Example.app/Contents/ordinary.bin")
        let result = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: file.deletingLastPathComponent()))
        let node = try XCTUnwrap(result.nodes[file.path])
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
    }

    func testKnownCloudLocationsAreRefusedEvenWithLocallyAvailableMetadata() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        for cloud in ["CloudStorage", "Mobile Documents"] {
            let file = try fixture.file("Library/\(cloud)/Provider/ordinary.bin")
            let result = try fixture.syntheticResult(file: file)
            let node = try XCTUnwrap(result.nodes[file.path])
            XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
        }
    }

    func testOutOfRootPathIsRefusedEvenIfListedInResult() throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/ordinary.bin")
        let outside = try fixture.file("elsewhere/outside.bin")
        let result = try fixture.syntheticResult(file: outside, root: fixture.scanRoot)
        let node = try XCTUnwrap(result.nodes[outside.path])
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
    }

    func testMissingSnapshotIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let result = try await fixture.scan()
        let node = StorageMapNode(id: file.path, url: file, name: file.lastPathComponent, isDirectory: false,
                                  isPackage: false, byteCount: 8_192, fileCount: 1, childIDs: [], isPartial: false)
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
    }

    func testHardLinkAliasUsesOwnAllocationAndOnlyPassesSelectedPath() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let original = try fixture.file("parent/scan/a.bin")
        let alias = fixture.url("parent/scan/z.bin")
        try FileManager.default.linkItem(at: original, to: alias)
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[alias.path])
        XCTAssertEqual(node.byteCount, 0)
        let request = try StorageMapTrash.prepare(node: node, in: result)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: alias).allocatedBytes)
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls, [alias])
    }

    func testHiddenFilesAreSupportedWithExplicitConfirmationRequest() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/.hidden.bin")
        let request = try await fixture.request(for: file)
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls, [file])
    }

    func testUnrelatedFolderContentChangesDoNotInvalidateFileChoice() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        _ = try fixture.file("parent/scan/new.bin")
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls, [file])
    }

    func testTrashFailureIsReturnedWithoutDeletingFile() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        let calls = TrashCalls()
        let service = StorageMapTrash { url in
            calls.record(url)
            throw NSError(domain: "TrashFixture", code: 7)
        }
        do {
            try await service.moveToTrash(request: request)
            XCTFail("Expected the system Trash error")
        } catch {
            XCTAssertEqual((error as NSError).domain, "TrashFixture")
            XCTAssertEqual((error as NSError).code, 7)
        }
        XCTAssertEqual(calls.urls, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancelledOperationNeverCallsTrashHandler() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/ordinary.bin")
        let request = try await fixture.request(for: file)
        let calls = TrashCalls()
        let service = StorageMapTrash(trashItem: calls.record)
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.moveToTrash(request: request)
        }
        do {
            try await operation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(calls.urls.isEmpty)
    }

    func testFolderRequestPassesOnlyWholeSelectedFolderToTrash() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/nested/file.bin")
        let folder = fixture.url("parent/scan/folder")
        let request = try await fixture.request(for: folder)
        let calls = TrashCalls()
        XCTAssertTrue(request.isDirectory)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: file).allocatedBytes)
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEmptyFolderCanBePreparedAndTrashed() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let folder = fixture.url("parent/scan/empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = try await fixture.request(for: folder)
        let calls = TrashCalls()
        XCTAssertTrue(request.isDirectory)
        XCTAssertEqual(request.byteCount, 0)
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
    }

    func testFolderConfirmationIncludesHiddenContentsOmittedFromMap() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let visible = try fixture.file("parent/scan/folder/visible.bin")
        let hidden = try fixture.file("parent/scan/folder/.hidden/secret.bin")
        let folder = fixture.url("parent/scan/folder")
        let result = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: fixture.scanRoot, includeHidden: false))
        let node = try XCTUnwrap(result.nodes[folder.path])
        XCTAssertNil(result.nodes[hidden.path])
        let request = try StorageMapTrash.prepare(node: node, in: result)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: visible).allocatedBytes + FileSafety.snapshot(of: hidden).allocatedBytes)
        XCTAssertGreaterThan(request.byteCount, node.byteCount)
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
    }

    func testPartialFolderMapIsFreshlyAndCompletelyVerified() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/nested/file.bin")
        let folder = fixture.url("parent/scan/folder")
        let result = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: fixture.scanRoot, maximumDepth: 1))
        let node = try XCTUnwrap(result.nodes[folder.path])
        XCTAssertTrue(node.isPartial)
        XCTAssertEqual(node.byteCount, 0)
        let request = try StorageMapTrash.prepare(node: node, in: result)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: file).allocatedBytes)
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
    }

    func testFolderChildContentChangedAfterConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/nested/file.bin")
        let request = try await fixture.request(for: fixture.url("parent/scan/folder"))
        try Data(repeating: 2, count: 8_192).write(to: file)
        await assertNoTrash(request)
    }

    func testFolderHiddenChildChangedAfterConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/.hidden/file.bin")
        let folder = fixture.url("parent/scan/folder")
        let result = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: fixture.scanRoot, includeHidden: false))
        let request = try StorageMapTrash.prepare(node: XCTUnwrap(result.nodes[folder.path]), in: result)
        try Data(repeating: 2, count: 8_192).write(to: file)
        await assertNoTrash(request)
    }

    func testFolderDescendantAddedRemovedOrReplacedAfterConfirmationIsRefused() async throws {
        for mutation in 0..<3 {
            let fixture = try TrashFixture()
            defer { fixture.remove() }
            let file = try fixture.file("parent/scan/folder/nested/file.bin")
            let request = try await fixture.request(for: fixture.url("parent/scan/folder"))
            switch mutation {
            case 0: _ = try fixture.file("parent/scan/folder/nested/added.bin")
            case 1: try FileManager.default.removeItem(at: file)
            default:
                try FileManager.default.moveItem(at: file, to: fixture.url("saved.bin"))
                _ = try fixture.file("parent/scan/folder/nested/file.bin")
            }
            await assertNoTrash(request)
        }
    }

    func testFolderReplacedAfterConfirmationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/folder/nested/file.bin")
        let folder = fixture.url("parent/scan/folder")
        let request = try await fixture.request(for: folder)
        try FileManager.default.moveItem(at: folder, to: fixture.url("saved-folder"))
        _ = try fixture.file("parent/scan/folder/nested/file.bin")
        await assertNoTrash(request)
    }

    func testFolderWithSymbolicLinkIsRefusedWithoutFollowingTarget() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let outside = try fixture.file("outside/file.bin")
        let folder = fixture.url("parent/scan/folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[folder.path])
        XCTAssertTrue(node.isPartial)
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result))
        XCTAssertEqual(try Data(contentsOf: outside).count, 8_192)
    }

    func testFolderDescendantReplacedBySymbolicLinkIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let file = try fixture.file("parent/scan/folder/nested/file.bin")
        let outside = try fixture.file("outside/file.bin")
        let request = try await fixture.request(for: fixture.url("parent/scan/folder"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await assertNoTrash(request)
    }

    func testFolderContainingPackageIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/folder/Example.app/Contents/program")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[fixture.url("parent/scan/folder").path])
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result)) { error in
            XCTAssertTrue(error.localizedDescription.contains("packages"))
        }
    }

    func testFolderContainingKnownCloudLocationIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/folder/Library/CloudStorage/Provider/file.bin")
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[fixture.url("parent/scan/folder").path])
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Cloud"))
        }
    }

    func testFolderContainingSpecialFileIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let folder = fixture.url("parent/scan/folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe").path, mode_t(0o600)), 0)
        let result = try await fixture.scan()
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: XCTUnwrap(result.nodes[folder.path]), in: result))
    }

    func testFolderBeyondVerificationDepthIsRefused() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let folder = fixture.url("parent/scan/folder")
        var nested = folder
        for _ in 0..<65 { nested.appendPathComponent("child") }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[folder.path])
        XCTAssertTrue(node.isPartial)
        XCTAssertThrowsError(try StorageMapTrash.prepare(node: node, in: result)) { error in
            XCTAssertTrue(error.localizedDescription.contains("too deep"))
        }
    }

    func testFolderHardLinksCountOnceWithoutDependingOnSiblingMapAttribution() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        let outside = try fixture.file("parent/scan/a.bin")
        let folder = fixture.url("parent/scan/folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: outside, to: folder.appendingPathComponent("first.bin"))
        try FileManager.default.linkItem(at: outside, to: folder.appendingPathComponent("second.bin"))
        let result = try await fixture.scan()
        let node = try XCTUnwrap(result.nodes[folder.path])
        XCTAssertEqual(node.byteCount, 0)
        let request = try StorageMapTrash.prepare(node: node, in: result)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: outside).allocatedBytes)
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
    }

    func testSiblingChangesDoNotInvalidateFolderConfirmation() async throws {
        let fixture = try TrashFixture()
        defer { fixture.remove() }
        _ = try fixture.file("parent/scan/folder/nested/file.bin")
        let folder = fixture.url("parent/scan/folder")
        let request = try await fixture.request(for: folder)
        _ = try fixture.file("parent/scan/unrelated.bin")
        let calls = TrashCalls()
        try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
        XCTAssertEqual(calls.urls.map(\.path), [folder.path])
    }

    private func assertNoTrash(_ request: StorageMapTrashRequest, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = TrashCalls()
        do {
            try await StorageMapTrash(trashItem: calls.record).moveToTrash(request: request)
            XCTFail("Expected changed file or path to be refused", file: file, line: line)
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
        XCTAssertTrue(calls.urls.isEmpty, file: file, line: line)
    }
}

private final class TrashCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func record(_ url: URL) { lock.withLock { recorded.append(url) } }
}

private struct TrashFixture {
    let root: URL
    var scanRoot: URL { url("parent/scan") }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacTools-TrashTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func file(_ path: String) throws -> URL {
        let file = url(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: file)
        return file
    }

    func scan() async throws -> StorageMapResult {
        try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: scanRoot))
    }

    func request(for file: URL) async throws -> StorageMapTrashRequest {
        let result = try await scan()
        let node = try XCTUnwrap(result.nodes[file.path])
        return try StorageMapTrash.prepare(node: node, in: result)
    }

    /// Adversarial records check that fresh validation does not trust metadata
    /// or result membership alone; normal requests always use the real scanner.
    func syntheticResult(file: URL, root chosenRoot: URL? = nil) throws -> StorageMapResult {
        let folder = chosenRoot ?? file.deletingLastPathComponent()
        let node = StorageMapNode(id: file.path, url: file, name: file.lastPathComponent, isDirectory: false,
                                  isPackage: false, byteCount: 8_192, fileCount: 1, childIDs: [], isPartial: false,
                                  snapshot: try FileSafety.snapshot(of: file))
        let rootNode = StorageMapNode(id: folder.path, url: folder, name: folder.lastPathComponent, isDirectory: true,
                                      isPackage: false, byteCount: 8_192, fileCount: 1, childIDs: [file.path], isPartial: false,
                                      snapshot: try FileSafety.snapshot(of: folder))
        return StorageMapResult(rootID: folder.path, nodes: [folder.path: rootNode, file.path: node], issues: [], enumeratedCount: 1,
                                inspectedCount: 1, reachedLimit: false)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
