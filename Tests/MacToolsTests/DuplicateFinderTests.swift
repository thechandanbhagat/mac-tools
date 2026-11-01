import Darwin
import Foundation
import XCTest
@testable import MacTools

final class DuplicateFinderTests: XCTestCase, @unchecked Sendable {
    func testFindsContentMatchesNotJustNamesOrSizes() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let a = try fixture.file("A/a.txt", "same content")
        let b = try fixture.file("B/different-name.bin", "same content")
        _ = try fixture.file("C/a.txt", "xxxx content")
        let result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].files.map(\.url)), [a, b])
        XCTAssertEqual(result.groups[0].byteCount, 12)
    }

    func testHardLinksAreNotAdditionalCopies() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let a = try fixture.file("original.txt", "content")
        try FileManager.default.linkItem(at: a, to: fixture.root.appendingPathComponent("link.txt"))
        var result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertTrue(result.groups.isEmpty)
        _ = try fixture.file("copy.txt", "content")
        result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertEqual(result.groups[0].files.count, 2)
    }

    func testSkipsLinksPackagesHiddenFilesAndKnownCloudPaths() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let a = try fixture.file("original.txt", "content")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked.txt"), withDestinationURL: a)
        _ = try fixture.file(".hidden.txt", "content")
        _ = try fixture.file("Example.app/Contents/Copy.txt", "content")
        _ = try fixture.file("CloudStorage/Provider/Copy.txt", "content")
        let result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testEntryLimitProducesVisiblePartialNotice() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        for n in 0..<5 { _ = try fixture.file("\(n).txt", "same") }
        let result = try await DuplicateFinder(maximumEntries: 2).scan(root: fixture.root)
        XCTAssertEqual(result.inspectedCount, 2)
        XCTAssertTrue(result.issues.contains { $0.message.contains("stopped") })
    }

    func testSelectionMustKeepOneCopyAndBelongToResults() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let service = DuplicateFinder()
        let groups = try await service.scan(root: fixture.root).groups
        XCTAssertThrowsError(try service.prepare(groups: groups, selectedIDs: []))
        XCTAssertThrowsError(try service.prepare(groups: groups, selectedIDs: Set(groups[0].files.map(\.id))))
        XCTAssertThrowsError(try service.prepare(groups: groups, selectedIDs: ["unknown"]))
        XCTAssertEqual(try service.prepare(groups: groups, selectedIDs: [groups[0].files[0].id]).files.count, 1)
    }

    func testConfirmedSelectionMovesOnlySelectedCopy() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let destination = fixture.container.appendingPathComponent("Moved.txt")
        let service = DuplicateFinder(trashItem: { try FileManager.default.moveItem(at: $0, to: destination) })
        let groups = try await service.scan(root: fixture.root).groups
        let selected = groups[0].files[0], kept = groups[0].files[1]
        let result = await service.moveToTrash(try service.prepare(groups: groups, selectedIDs: [selected.id]))
        XCTAssertEqual(result.movedIDs, [selected.id]); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.url.path))
        XCTAssertEqual(try String(contentsOf: kept.url, encoding: .utf8), "same")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "same")
    }

    func testChangedKeeperPreventsAnyRemoval() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let recorder = DuplicateRecorder()
        let service = DuplicateFinder(trashItem: { recorder.record($0) })
        let groups = try await service.scan(root: fixture.root).groups
        let request = try service.prepare(groups: groups, selectedIDs: [groups[0].files[0].id])
        try Data("edited".utf8).write(to: groups[0].files[1].url)
        let result = await service.moveToTrash(request)
        XCTAssertTrue(result.movedIDs.isEmpty); XCTAssertFalse(result.failures.isEmpty); XCTAssertEqual(recorder.count, 0)
    }

    func testChangedSelectedFilePreventsRemoval() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let recorder = DuplicateRecorder()
        let service = DuplicateFinder(trashItem: { recorder.record($0) })
        let groups = try await service.scan(root: fixture.root).groups
        let selected = groups[0].files[0]
        let request = try service.prepare(groups: groups, selectedIDs: [selected.id])
        try Data("edit".utf8).write(to: selected.url)
        let result = await service.moveToTrash(request)
        XCTAssertTrue(result.movedIDs.isEmpty); XCTAssertFalse(result.failures.isEmpty); XCTAssertEqual(recorder.count, 0)
    }

    func testReplacedParentPreventsRemoval() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("Folder/a.txt", "same"); _ = try fixture.file("Folder/b.txt", "same")
        let recorder = DuplicateRecorder()
        let service = DuplicateFinder(trashItem: { recorder.record($0) })
        let groups = try await service.scan(root: fixture.root).groups
        let request = try service.prepare(groups: groups, selectedIDs: [groups[0].files[0].id])
        let parent = fixture.root.appendingPathComponent("Folder")
        try FileManager.default.moveItem(at: parent, to: fixture.container.appendingPathComponent("Old"))
        _ = try fixture.file("Folder/a.txt", "same"); _ = try fixture.file("Folder/b.txt", "same")
        let result = await service.moveToTrash(request)
        XCTAssertTrue(result.movedIDs.isEmpty); XCTAssertEqual(recorder.count, 0)
    }

    func testCancelledScanDoesNotProduceResults() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let task = Task { try await DuplicateFinder().scan(root: fixture.root) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancelledRemovalDoesNotCallTrashHandler() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("a.txt", "same"); _ = try fixture.file("b.txt", "same")
        let recorder = DuplicateRecorder()
        let service = DuplicateFinder(trashItem: { recorder.record($0) })
        let groups = try await service.scan(root: fixture.root).groups
        let request = try service.prepare(groups: groups, selectedIDs: [groups[0].files[0].id])
        let task = Task { await service.moveToTrash(request) }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.movedIDs.isEmpty); XCTAssertEqual(recorder.count, 0)
    }

    func testHashStreamsMultiMegabyteFilesAndRejectsChangedSnapshot() throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let url = try fixture.file("a.bin", "")
        try Data(repeating: 0x61, count: 3_000_000).write(to: url)
        let snapshot = try FileSafety.snapshot(of: url)
        XCTAssertEqual(try DuplicateFileAccess.digest(url, snapshot: snapshot).count, 64)
        try Data("changed".utf8).write(to: url)
        XCTAssertThrowsError(try DuplicateFileAccess.digest(url, snapshot: snapshot))
    }

    func testDifferentResourceForkContentsAreSkippedWithVisibleNotices() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let first = try fixture.file("first.dat", ""), second = try fixture.file("second.dat", "")
        try setResourceFork(first, content: "first unique resource")
        try setResourceFork(second, content: "second unique resource")
        let result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(Set(result.issues.map(\.path)), [first.path, second.path])
        XCTAssertTrue(result.issues.allSatisfy { $0.message.contains("resource fork") })
        // The restriction must not prevent a safe rename of an ordinary resource-bearing file.
        var options = BatchRenameOptions(); options.prefix = "New-"
        XCTAssertEqual(try BatchRenamer().preview(files: [first], options: options).changes.count, 1)
    }

    func testResourceForkAddedAfterScanPreventsTrash() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        _ = try fixture.file("first.dat", "same"); _ = try fixture.file("second.dat", "same")
        let recorder = DuplicateRecorder()
        let service = DuplicateFinder(trashItem: { recorder.record($0) })
        let groups = try await service.scan(root: fixture.root).groups
        let selected = try XCTUnwrap(groups.first?.files.first)
        let request = try service.prepare(groups: groups, selectedIDs: [selected.id])
        try setResourceFork(selected.url, content: "unique added resource")
        let result = await service.moveToTrash(request)
        XCTAssertTrue(result.movedIDs.isEmpty); XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(recorder.count, 0)
    }

    func testDigestRefusesResourceForkEvenWithCurrentSnapshot() throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let file = try fixture.file("content.dat", "ordinary data")
        try setResourceFork(file, content: "separate resource data")
        let snapshot = try DuplicateFileAccess.validate(file)
        XCTAssertThrowsError(try DuplicateFileAccess.digest(file, snapshot: snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("resource fork"))
        }
    }

    func testFinderAliasIsSkippedWithoutResolvingItsTarget() async throws {
        let fixture = try DuplicateFixture(); defer { fixture.remove() }
        let target = try fixture.file("target.txt", "target")
        let alias = fixture.root.appendingPathComponent("Target alias")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let result = try await DuplicateFinder().scan(root: fixture.root)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.path == alias.path && $0.message.contains("aliases") })
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target")
    }

    private func setResourceFork(_ url: URL, content: String) throws {
        let data = Data(content.utf8)
        let status = data.withUnsafeBytes { buffer in
            setxattr(url.path, "com.apple.ResourceFork", buffer.baseAddress, buffer.count, 0, 0)
        }
        guard status == 0 else { throw DuplicateFileAccess.posix(url) }
    }
}

private struct DuplicateFixture {
    let container = URL(fileURLWithPath: "/private/tmp/MacTools-DuplicateTest-\(UUID().uuidString)", isDirectory: true)
    var root: URL { container.appendingPathComponent("Files", isDirectory: true) }
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ path: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url); return url
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
}
private final class DuplicateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record(_ url: URL) { lock.withLock { calls += 1 } }
}
