import Darwin
import Foundation
import XCTest
@testable import MacTools

@MainActor
final class StorageMapTests: XCTestCase {
    func testNestedFoldersAggregateAllocatedBytesAndSortLargestFirst() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let first = try fixture.file("scan/a/small.bin", bytes: 512)
        let second = try fixture.file("scan/b/large.bin", bytes: 32_768)
        let direct = try fixture.file("scan/direct.bin", bytes: 8_192)
        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())
        let root = try XCTUnwrap(result.nodes[result.rootID])
        let expected = try [first, second, direct].reduce(Int64(0)) { try $0 + FileSafety.snapshot(of: $1).allocatedBytes }

        XCTAssertEqual(root.byteCount, expected)
        XCTAssertEqual(root.fileCount, 3)
        XCTAssertEqual(root.childIDs.reduce(Int64(0)) { $0 + result.nodes[$1]!.byteCount }, root.byteCount)
        XCTAssertEqual(root.childIDs.map { result.nodes[$0]!.byteCount }, root.childIDs.map { result.nodes[$0]!.byteCount }.sorted(by: >))
        XCTAssertEqual(result.nodes[first.deletingLastPathComponent().path]?.childIDs, [first.path])
        XCTAssertFalse(root.isPartial)
        XCTAssertFalse(result.reachedLimit)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.enumeratedCount, 5)
        XCTAssertEqual(result.inspectedCount, 5)
    }

    func testHiddenEntriesAreIncludedByDefaultAndCanBeExcluded() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/visible.bin", bytes: 64)
        let hiddenFile = try fixture.file("scan/.hidden.bin", bytes: 64)
        let hiddenChild = try fixture.file("scan/.folder/nested.bin", bytes: 64)
        let finderHidden = try fixture.file("scan/finder-hidden.bin", bytes: 64)
        XCTAssertEqual(chflags(finderHidden.path, UInt32(UF_HIDDEN)), 0)

        let included = try await StorageMapScanner().scan(configuration: fixture.configuration())
        XCTAssertEqual(included.nodes[included.rootID]?.fileCount, 4)
        XCTAssertNotNil(included.nodes[hiddenFile.path])
        XCTAssertNotNil(included.nodes[hiddenChild.path])
        XCTAssertNotNil(included.nodes[finderHidden.path])

        var config = fixture.configuration()
        config.includeHidden = false
        let excluded = try await StorageMapScanner().scan(configuration: config)
        XCTAssertEqual(excluded.nodes[excluded.rootID]?.fileCount, 1)
        XCTAssertNil(excluded.nodes[hiddenFile.path])
        XCTAssertNil(excluded.nodes[hiddenChild.path])
        XCTAssertNil(excluded.nodes[finderHidden.path])
        XCTAssertEqual(excluded.nodes[excluded.rootID]?.isPartial, false)
    }

    func testSymlinkFilesAndDirectoriesAreNeverFollowed() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/ordinary.bin", bytes: 64)
        let outside = try fixture.file("outside/important.bin", bytes: 64)
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/link-file"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/link-dir"), withDestinationURL: fixture.url("outside"))
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/loop"), withDestinationURL: fixture.url("scan"))

        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())

        XCTAssertEqual(result.nodes[result.rootID]?.fileCount, 1)
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.issues.contains { $0.message.contains("3 symbolic links") })
        XCTAssertEqual(try Data(contentsOf: outside).count, 64)
    }

    func testPackagesAreVisibleAggregateLeaves() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let binary = try fixture.file("scan/Example.app/Contents/MacOS/program", bytes: 8_192)
        _ = try fixture.file("scan/Example.app/Contents/Resources/icon.bin", bytes: 64)
        let packageURL = fixture.url("scan/Example.app")
        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())
        let package = try XCTUnwrap(result.nodes[packageURL.path])

        XCTAssertTrue(package.isDirectory)
        XCTAssertTrue(package.isPackage)
        XCTAssertTrue(package.childIDs.isEmpty)
        XCTAssertEqual(package.fileCount, 2)
        XCTAssertEqual(result.nodes[result.rootID]?.byteCount, package.byteCount)
        XCTAssertNil(result.nodes[binary.path])
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertFalse(package.isPartial)
    }

    func testSelectedPackageRootAlsoAggregatesAsALeaf() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("Example.app/Contents/program", bytes: 64)

        let result = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: fixture.url("Example.app")))
        let root = try XCTUnwrap(result.nodes[result.rootID])

        XCTAssertTrue(root.isPackage)
        XCTAssertTrue(root.childIDs.isEmpty)
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertEqual(result.nodes.count, 1)
    }

    func testHardLinksRetainBothPathsAndCountStorageOnlyOnce() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let original = try fixture.file("scan/a-original.bin", bytes: 8_192)
        try FileManager.default.createDirectory(at: fixture.url("scan/z-folder"), withIntermediateDirectories: true)
        let alias = fixture.url("scan/z-folder/alias.bin")
        try FileManager.default.linkItem(at: original, to: alias)

        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())

        XCTAssertEqual(result.nodes[result.rootID]?.byteCount, try FileSafety.snapshot(of: original).allocatedBytes)
        XCTAssertEqual(result.nodes[result.rootID]?.fileCount, 2)
        XCTAssertEqual(result.nodes[result.rootID]?.sharedFileCount, 1)
        XCTAssertEqual(result.nodes[alias.path]?.byteCount, 0)
        XCTAssertEqual(result.nodes[alias.path]?.sharedFileCount, 1)
        XCTAssertNotNil(result.nodes[original.path])
        XCTAssertEqual(result.nodes[original.path]?.sharedFileCount, 0)
        XCTAssertEqual(result.nodes[fixture.url("scan/z-folder").path]?.byteCount, 0)
        XCTAssertEqual(result.nodes[fixture.url("scan/z-folder").path]?.sharedFileCount, 1)
    }

    func testEntryLimitBoundsEnumerationAndSortsReturnedPaths() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        for name in ["z.bin", "c.bin", "e.bin", "a.bin", "b.bin", "d.bin"] {
            _ = try fixture.file("scan/\(name)", bytes: 64)
        }
        var config = fixture.configuration()
        config.maximumEntries = 3

        let result = try await StorageMapScanner().scan(configuration: config)
        let root = try XCTUnwrap(result.nodes[result.rootID])

        let names = root.childIDs.map { result.nodes[$0]!.name }
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(names.count, 3)
        XCTAssertEqual(result.enumeratedCount, 3)
        XCTAssertEqual(result.inspectedCount, 3)
        XCTAssertEqual(result.nodes.count, 4)
        XCTAssertTrue(result.reachedLimit)
        XCTAssertTrue(root.isPartial)
        XCTAssertTrue(result.issues.contains { $0.message.contains("limit") })
    }

    func testDepthLimitRetainsFolderAndPropagatesPartialStatus() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/a/b/deep.bin", bytes: 64)
        _ = try fixture.file("scan/a/visible.bin", bytes: 64)
        var config = fixture.configuration()
        config.maximumDepth = 1

        let result = try await StorageMapScanner().scan(configuration: config)

        XCTAssertTrue(result.reachedLimit)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertEqual(result.nodes[fixture.url("scan/a").path]?.isPartial, true)
        XCTAssertEqual(result.nodes[fixture.url("scan/a").path]?.childIDs, [])
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[result.rootID]?.fileCount, 0)
        XCTAssertEqual(result.enumeratedCount, 2)
    }

    func testExactBudgetConservativelyMarksPartialAndEmptyFoldersStayComplete() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/only.bin", bytes: 64)
        var config = fixture.configuration()
        config.maximumEntries = 1
        let result = try await StorageMapScanner().scan(configuration: config)
        // With no spare enumeration budget, the scanner cannot prove EOF
        // without reading past the cap. It reports a conservative partial map.
        XCTAssertTrue(result.reachedLimit)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertEqual(result.enumeratedCount, 1)

        try FileManager.default.createDirectory(at: fixture.url("empty"), withIntermediateDirectories: true)
        let empty = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: fixture.url("empty"), maximumDepth: 0))
        XCTAssertFalse(empty.reachedLimit)
        XCTAssertEqual(empty.nodes[empty.rootID]?.byteCount, 0)
        XCTAssertEqual(empty.nodes[empty.rootID]?.fileCount, 0)
        XCTAssertEqual(empty.nodes[empty.rootID]?.isPartial, false)
        XCTAssertEqual(empty.enumeratedCount, 0)
    }

    func testGlobalEnumerationBudgetRetainsAlreadyCollectedParentSiblings() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        for index in 0..<20 { _ = try fixture.file("scan/a-folder/item-\(index).bin", bytes: 64) }
        let sibling = try fixture.file("scan/z-sibling.bin", bytes: 64)
        var config = fixture.configuration()
        config.maximumEntries = 3

        let result = try await StorageMapScanner().scan(configuration: config)

        XCTAssertEqual(result.enumeratedCount, 3)
        XCTAssertEqual(result.inspectedCount, 3)
        XCTAssertNotNil(result.nodes[sibling.path])
        XCTAssertEqual(result.nodes[result.rootID]?.fileCount, 2)
        XCTAssertEqual(result.nodes[fixture.url("scan/a-folder").path]?.isPartial, true)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.reachedLimit)
    }

    func testExcludedHiddenNamesStillConsumeEnumerationBudget() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        for index in 0..<20 { _ = try fixture.file("scan/.hidden-\(index)", bytes: 64) }
        var config = fixture.configuration()
        config.maximumEntries = 3
        config.includeHidden = false

        let result = try await StorageMapScanner().scan(configuration: config)

        XCTAssertEqual(result.enumeratedCount, 3)
        XCTAssertEqual(result.inspectedCount, 0)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.reachedLimit)
    }

    func testDepthLimitProbesOnlyOneEntryInLargeFolder() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        for index in 0..<20 { _ = try fixture.file("scan/item-\(index).bin", bytes: 64) }
        var config = fixture.configuration()
        config.maximumDepth = 0

        let result = try await StorageMapScanner().scan(configuration: config)

        XCTAssertEqual(result.enumeratedCount, 1)
        XCTAssertEqual(result.inspectedCount, 0)
        XCTAssertEqual(result.nodes.count, 1)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.reachedLimit)
    }

    func testCloudProviderTreesAreSkippedWithoutCountingTheirFiles() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let cloudFile = try fixture.file("scan/Library/CloudStorage/Provider/online.bin", bytes: 64)
        _ = try fixture.file("scan/Library/local.bin", bytes: 64)

        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())

        XCTAssertEqual(result.nodes[result.rootID]?.fileCount, 1)
        XCTAssertNil(result.nodes[cloudFile.path])
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.issues.contains { $0.message.contains("cloud") })
    }

    func testMissingFileAndSymlinkRootsAreRejected() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        let file = try fixture.file("outside/ordinary.bin", bytes: 64)
        try FileManager.default.createSymbolicLink(at: fixture.url("linked"), withDestinationURL: fixture.url("outside"))
        for root in [fixture.url("missing"), file, fixture.url("linked"), fixture.url("linked/nested")] {
            do {
                _ = try await StorageMapScanner().scan(configuration: StorageMapConfiguration(root: root))
                XCTFail("Invalid root must fail: \(root.path)")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testUnreadableDirectoryIsVisibleAndPartial() async throws {
        guard getuid() != 0 else { throw XCTSkip("Root can read permission-restricted fixture directories.") }
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/private/secret.bin", bytes: 64)
        let restricted = fixture.url("scan/private")
        XCTAssertEqual(chmod(restricted.path, 0), 0)
        defer { _ = chmod(restricted.path, mode_t(0o700)) }

        let result = try await StorageMapScanner().scan(configuration: fixture.configuration())

        XCTAssertEqual(result.nodes[restricted.path]?.isPartial, true)
        XCTAssertEqual(result.nodes[result.rootID]?.isPartial, true)
        XCTAssertTrue(result.issues.contains { $0.path == restricted.path })
    }

    func testCancellationPropagatesWithoutReturningResults() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/file.bin", bytes: 64)
        let config = fixture.configuration()
        let task = Task { try await StorageMapScanner().scan(configuration: config) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled scans must throw.")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancellationDuringEnumerationStopsWorker() async throws {
        let fixture = try MapFixture()
        defer { fixture.remove() }
        for index in 0..<20 { _ = try fixture.file("scan/item-\(index).bin", bytes: 64) }

        do {
            _ = try await StorageMapScanner().scan(configuration: fixture.configuration()) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
            XCTFail("A worker cancelled during progress must throw.")
        } catch is CancellationError {
            // Progress is emitted on the detached worker, which checks cancellation.
        }
    }
}

private struct MapFixture {
    let root: URL

    init() throws {
        // Foundation preserves the /var alias on some macOS releases; use a
        // literal canonical temporary path for no-follow descriptor traversal.
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacToolsMapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative).standardized }

    func file(_ relative: String, bytes: Int) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 17, count: bytes).write(to: target)
        return target
    }

    func configuration() -> StorageMapConfiguration { StorageMapConfiguration(root: url("scan")) }

    func remove() {
        precondition(root.lastPathComponent.hasPrefix("MacToolsMapTests-"))
        try? FileManager.default.removeItem(at: root)
    }
}
