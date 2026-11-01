import Foundation
import XCTest
@testable import MacTools

@MainActor
final class StorageSafetyTests: XCTestCase {
    func testScanSkipsSymlinksHiddenFilesAndPackagesAndNeverReturnsDirectories() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let ordinary = try fixture.file("scan/normal/cache.dat", bytes: 32)
        _ = try fixture.file("scan/.hidden/secret.dat", bytes: 32)
        _ = try fixture.file("scan/.secret", bytes: 32)
        _ = try fixture.file("scan/Example.app/Contents/Resources/binary", bytes: 32)
        let outside = try fixture.file("outside/important.dat", bytes: 32)
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/file-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/folder-link"), withDestinationURL: fixture.url("outside"))

        let result = try await StorageScanner().scan(configuration: fixture.configuration())

        XCTAssertEqual(result.items.map(\.url), [ordinary])
        XCTAssertFalse(result.reachedLimit)
        XCTAssertTrue(result.items.allSatisfy { $0.byteCount > 0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testOverlappingRootsAndHardLinksAreCountedOnce() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let file = try fixture.file("scan/nested/data.bin", bytes: 128)
        try FileManager.default.linkItem(at: file, to: fixture.url("scan/hard-link.bin"))
        let config = ScanConfiguration(roots: [
            ScanRoot(url: fixture.url("scan"), category: .largeFiles),
            ScanRoot(url: fixture.url("scan/nested"), category: .downloads),
            ScanRoot(url: fixture.url("scan/nested"), category: .downloads)
        ], largeFileThresholdBytes: 1)

        let result = try await StorageScanner().scan(configuration: config)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.url, file)
        XCTAssertEqual(result.items.first?.category, .downloads)
        XCTAssertEqual(result.scannedBytes, result.items.first?.byteCount)
    }

    func testLargeFilesThresholdAndLimitsAreReported() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/small.bin", bytes: 20)
        let big = try fixture.file("scan/big.bin", bytes: 200)
        var config = fixture.configuration(category: .largeFiles)
        config.largeFileThresholdBytes = 100

        let result = try await StorageScanner().scan(configuration: config)
        XCTAssertEqual(result.items.map(\.url), [big])

        config.maximumEntries = 1
        let limited = try await StorageScanner().scan(configuration: config)
        XCTAssertTrue(limited.reachedLimit)
        XCTAssertEqual(limited.inspectedCount, 1)
        XCTAssertTrue(limited.issues.contains { $0.path == CleanupCategory.largeFiles.title })
    }

    func testBusyCachesCannotConsumeDownloadsItemOrEntryBudget() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        for index in 0..<8 {
            _ = try fixture.file("application-caches/cache-\(index).bin", bytes: 32)
        }
        let download = try fixture.file("downloads/keep-visible.bin", bytes: 32)
        let roots = [
            ScanRoot(url: fixture.url("application-caches"), category: .caches),
            ScanRoot(url: fixture.url("downloads"), category: .downloads)
        ]
        // Exercise each cap independently: both must reserve Downloads a share.
        for config in [
            ScanConfiguration(roots: roots, maximumEntries: 100, maximumItems: 4),
            ScanConfiguration(roots: roots, maximumEntries: 4, maximumItems: 100)
        ] {
            let result = try await StorageScanner().scan(configuration: config)

            XCTAssertEqual(result.items.filter { $0.category == .caches }.count, 2)
            XCTAssertEqual(result.items.filter { $0.category == .downloads }.map(\.url), [download])
            XCTAssertLessThanOrEqual(result.items.count, config.maximumItems)
            XCTAssertLessThanOrEqual(result.inspectedCount, config.maximumEntries)
            XCTAssertTrue(result.reachedLimit)
            XCTAssertTrue(result.issues.contains { $0.path == CleanupCategory.caches.title })
            XCTAssertFalse(result.issues.contains { $0.path == CleanupCategory.downloads.title })
        }
    }

    func testLargeFileRootsShareOneCategoryBudget() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        for index in 0..<4 {
            _ = try fixture.file("documents/data-\(index).bin", bytes: 32)
            _ = try fixture.file("desktop/data-\(index).bin", bytes: 32)
        }
        let download = try fixture.file("downloads/visible.bin", bytes: 32)
        let config = ScanConfiguration(roots: [
            ScanRoot(url: fixture.url("documents"), category: .largeFiles),
            ScanRoot(url: fixture.url("desktop"), category: .largeFiles),
            ScanRoot(url: fixture.url("downloads"), category: .downloads)
        ], largeFileThresholdBytes: 1, maximumEntries: 100, maximumItems: 4)

        let result = try await StorageScanner().scan(configuration: config)

        XCTAssertEqual(result.items.filter { $0.category == .largeFiles }.count, 2)
        XCTAssertEqual(result.items.filter { $0.category == .downloads }.map(\.url), [download])
        XCTAssertEqual(result.issues.filter { $0.path == CleanupCategory.largeFiles.title }.count, 1)
        XCTAssertLessThanOrEqual(result.items.count, config.maximumItems)
    }

    func testMissingAndSymlinkRootsAreSurfacedWithoutFollowingThem() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("outside/important.bin", bytes: 20)
        try FileManager.default.createSymbolicLink(at: fixture.url("linked-root"), withDestinationURL: fixture.url("outside"))
        let config = ScanConfiguration(roots: [
            ScanRoot(url: fixture.url("missing"), category: .caches),
            ScanRoot(url: fixture.url("linked-root"), category: .downloads)
        ])

        let result = try await StorageScanner().scan(configuration: config)

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.count, 2)
    }

    func testCleanupOnlySendsExplicitlyReviewedFilesToTrashAndDeduplicatesThem() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/a.bin", bytes: 10)
        _ = try fixture.file("scan/b.bin", bytes: 20)
        let config = fixture.configuration()
        let result = try await StorageScanner().scan(configuration: config)
        let reviewed = try XCTUnwrap(result.items.first)
        let recorder = TrashRecorder()
        let cleaner = StorageCleaner(trashItem: recorder.record)

        let empty = try await cleaner.clean(reviewedItems: [], configuration: config)
        XCTAssertTrue(empty.movedItems.isEmpty)
        XCTAssertTrue(recorder.urls.isEmpty)

        let cleanup = try await cleaner.clean(reviewedItems: [reviewed, reviewed], configuration: config)

        XCTAssertEqual(recorder.urls, [reviewed.url])
        XCTAssertEqual(cleanup.movedItems, [reviewed])
        XCTAssertTrue(cleanup.failedItems.isEmpty)
        // The test mock only records requests. No test uses the real system Trash.
        XCTAssertTrue(result.items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCleanupRejectsChangedFilesAndUnapprovedRoots() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let file = try fixture.file("scan/data.bin", bytes: 64)
        let config = fixture.configuration()
        let scanned = try await StorageScanner().scan(configuration: config)
        let recorder = TrashRecorder()
        let cleaner = StorageCleaner(trashItem: recorder.record)

        let wrongRoots = try await cleaner.clean(reviewedItems: scanned.items, configuration: ScanConfiguration(roots: []))
        XCTAssertEqual(wrongRoots.failedItems.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty)

        try Data(repeating: 2, count: 64).write(to: file, options: .atomic)
        let changed = try await cleaner.clean(reviewedItems: scanned.items, configuration: config)
        XCTAssertEqual(changed.failedItems.count, 1)
        XCTAssertTrue(changed.movedItems.isEmpty)
        XCTAssertTrue(recorder.urls.isEmpty)
    }

    func testCleanupRejectsFileReplacedBySymlink() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let file = try fixture.file("scan/data.bin", bytes: 64)
        let outside = try fixture.file("outside/important.bin", bytes: 64)
        let config = fixture.configuration()
        let scanned = try await StorageScanner().scan(configuration: config)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let recorder = TrashRecorder()

        let cleanup = try await StorageCleaner(trashItem: recorder.record).clean(reviewedItems: scanned.items, configuration: config)

        XCTAssertTrue(cleanup.movedItems.isEmpty)
        XCTAssertEqual(cleanup.failedItems.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside).count, 64)
    }

    func testRootInsidePackageIsRejectedAndPrefixSiblingIsOutsideBoundary() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("Example.app/Contents/data.bin", bytes: 32)
        let config = ScanConfiguration(roots: [ScanRoot(url: fixture.url("Example.app/Contents"), category: .caches)])

        let result = try await StorageScanner().scan(configuration: config)

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertFalse(FileSafety.isDescendant(fixture.url("scan-other/data.bin"), of: fixture.url("scan")))
        XCTAssertFalse(FileSafety.isDescendant(fixture.url("scan"), of: fixture.url("scan")))
        XCTAssertTrue(FileSafety.isDescendant(fixture.url("scan/nested/data.bin"), of: fixture.url("scan")))
    }

    func testCleanupRejectsReplacedAncestorEvenWhenItPointsInsideAnotherAllowedRoot() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/nested/data.bin", bytes: 64)
        let outside = try fixture.file("other/data.bin", bytes: 64)
        let config = ScanConfiguration(roots: [
            ScanRoot(url: fixture.url("scan"), category: .caches),
            ScanRoot(url: fixture.url("other"), category: .downloads)
        ])
        let scanned = try await StorageScanner().scan(configuration: config)
        let original = try XCTUnwrap(scanned.items.first { $0.category == .caches })
        try FileManager.default.moveItem(at: fixture.url("scan/nested"), to: fixture.url("saved"))
        try FileManager.default.createSymbolicLink(at: fixture.url("scan/nested"), withDestinationURL: fixture.url("other"))
        let recorder = TrashRecorder()

        let cleanup = try await StorageCleaner(trashItem: recorder.record).clean(reviewedItems: [original], configuration: config)

        XCTAssertEqual(cleanup.failedItems.count, 1)
        XCTAssertTrue(recorder.urls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside).count, 64)
    }

    func testCleanupReportsTrashErrorsWithoutDeletingAnything() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let file = try fixture.file("scan/data.bin", bytes: 64)
        let config = fixture.configuration()
        let scanned = try await StorageScanner().scan(configuration: config)
        let cleaner = StorageCleaner { _ in throw CocoaError(.fileWriteNoPermission) }

        let cleanup = try await cleaner.clean(reviewedItems: scanned.items, configuration: config)

        XCTAssertTrue(cleanup.movedItems.isEmpty)
        XCTAssertEqual(cleanup.failedItems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testScanCancellationPropagatesToWorker() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/data.bin", bytes: 64)
        let config = fixture.configuration()
        let task = Task { try await StorageScanner().scan(configuration: config) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled scan must not return a successful result.")
        } catch is CancellationError {
            // Expected: the detached worker receives its parent's cancellation.
        }
    }

    func testCleanupCancellationDoesNotCallTrash() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        _ = try fixture.file("scan/data.bin", bytes: 64)
        let config = fixture.configuration()
        let scanned = try await StorageScanner().scan(configuration: config)
        let recorder = TrashRecorder()
        let cleaner = StorageCleaner(trashItem: recorder.record)
        let task = Task { try await cleaner.clean(reviewedItems: scanned.items, configuration: config) }
        task.cancel()

        do {
            let result = try await task.value
            XCTAssertTrue(result.isCancelled)
            XCTAssertTrue(result.movedItems.isEmpty)
        } catch is CancellationError {
            // Cancellation before the first item throws without any side effects.
        }
        XCTAssertTrue(recorder.urls.isEmpty)
    }
}

private struct TemporaryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("MacToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative).standardizedFileURL }

    func file(_ relative: String, bytes: Int) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: target)
        return target
    }

    func configuration(category: CleanupCategory = .caches) -> ScanConfiguration {
        ScanConfiguration(roots: [ScanRoot(url: url("scan"), category: category)])
    }

    func remove() {
        // Only fixture-owned temporary directories may be removed by test teardown.
        precondition(root.lastPathComponent.hasPrefix("MacToolsTests-"))
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] { lock.withLock { recorded } }

    @Sendable func record(_ url: URL) throws {
        lock.withLock { recorded.append(url) }
    }
}
