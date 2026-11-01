import Foundation
import XCTest
@testable import MacTools

@MainActor
final class StorageMapTrashModelTests: XCTestCase {
    func testRequestAndCancelNeverInvokeTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = TrashProbe()
        let model = StorageMapModel(isDemo: false, trashOperation: { request in await probe.record(request.url) })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        model.requestTrash(try XCTUnwrap(model.children.first { $0.name == "File.txt" }))
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNotNil(model.pendingTrash)
        let before = await probe.count
        XCTAssertEqual(before, 0)
        model.cancelTrash()
        model.confirmTrash()
        XCTAssertNil(model.pendingTrash)
        let after = await probe.count
        XCTAssertEqual(after, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testConfirmedTrashRefreshesCurrentFolderAndRemovesStaleResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("Moved file.txt")
        let model = StorageMapModel(isDemo: false, trashOperation: { request in
            try await StorageMapTrash(trashItem: { url in
                try FileManager.default.moveItem(at: url, to: destination)
            }).moveToTrash(request: request)
        })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        model.requestTrash(try XCTUnwrap(model.children.first { $0.name == "File.txt" }))
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNotNil(model.pendingTrash)
        model.confirmTrash()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
        XCTAssertNil(model.pendingTrash)
        XCTAssertEqual(model.currentURL, fixture.folder)
        XCTAssertNotNil(model.result)
        XCTAssertFalse(model.children.contains { $0.url == fixture.file })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.notice, "Moved “File.txt” to Trash.")
    }

    func testFolderRequestAndCancelNeverInvokeTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = TrashProbe()
        let model = StorageMapModel(isDemo: false, trashOperation: { request in await probe.record(request.url) })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        let folder = try XCTUnwrap(model.children.first { $0.name == "Child" })
        XCTAssertTrue(model.canTrash(folder))
        model.requestTrash(folder)
        try await waitUntil { !model.isPreparingTrash }
        let request = try XCTUnwrap(model.pendingTrash)
        XCTAssertTrue(request.isDirectory)
        XCTAssertEqual(request.url.path, fixture.child.path)
        XCTAssertEqual(request.byteCount, try FileSafety.snapshot(of: fixture.child.appendingPathComponent("Nested.txt")).allocatedBytes)
        model.cancelTrash()
        model.confirmTrash()
        XCTAssertNil(model.pendingTrash)
        let count = await probe.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.child.appendingPathComponent("Nested.txt").path))
    }

    func testConfirmedFolderMoveRefreshesParentAndRemovesFolderFromMap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("Moved Child", isDirectory: true)
        let model = StorageMapModel(isDemo: false, trashOperation: { request in
            try await StorageMapTrash(trashItem: { url in
                try FileManager.default.moveItem(at: url, to: destination)
            }).moveToTrash(request: request)
        })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        model.requestTrash(try XCTUnwrap(model.children.first { $0.name == "Child" }))
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertTrue(try XCTUnwrap(model.pendingTrash).isDirectory)
        model.confirmTrash()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentURL.path, fixture.folder.path)
        XCTAssertNotNil(model.result)
        XCTAssertFalse(model.children.contains { $0.url.path == fixture.child.path })
        XCTAssertTrue(model.children.contains { $0.url.path == fixture.file.path })
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Nested.txt").path))
        XCTAssertEqual(model.notice, "Moved “Child” to Trash.")
    }

    func testRescanOptionsAndNavigationInvalidateConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = TrashProbe()
        let model = StorageMapModel(isDemo: false, trashOperation: { request in await probe.record(request.url) })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        for action in 0..<3 {
            model.requestTrash(try XCTUnwrap(model.children.first { $0.name == "File.txt" }))
            try await waitUntil { !model.isPreparingTrash }
            XCTAssertNotNil(model.pendingTrash)
            if action == 0 { model.scan() }
            else if action == 1 { model.includeHidden.toggle() }
            else { model.navigate(to: try XCTUnwrap(model.children.first { $0.name == "Child" })) }
            XCTAssertNil(model.pendingTrash)
            model.confirmTrash()
            try await waitUntil { !model.isBusy }
        }
        let count = await probe.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.currentURL, fixture.child)
    }

    func testBusyTrashRejectsNavigationOptionsAndDuplicateConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let probe = TrashProbe()
        let model = StorageMapModel(isDemo: false, trashOperation: { request in try await probe.suspend(request.url) })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        model.navigate(to: try XCTUnwrap(model.children.first { $0.name == "Child" }))
        try await waitUntil { !model.isBusy }
        let file = try XCTUnwrap(model.children.first)
        let previousTime = model.scannedAt
        model.requestTrash(file)
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNotNil(model.pendingTrash)
        model.confirmTrash()
        try await waitForProbe(probe)
        let hidden = model.includeHidden
        model.includeHidden.toggle()
        model.goBack()
        model.goToRoot()
        model.scan()
        model.setRoot(fixture.container)
        model.requestTrash(file)
        model.confirmTrash()
        model.cancelTrash()
        XCTAssertTrue(model.isTrashing)
        XCTAssertFalse(model.canTrash(file))
        XCTAssertEqual(model.currentURL, fixture.child)
        XCTAssertEqual(model.includeHidden, hidden)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        await probe.fail()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.currentURL, fixture.child)
        XCTAssertEqual(model.scannedAt, previousTime)
        XCTAssertNotNil(model.result)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.errorTitle, "Unable to move item to Trash")
    }

    func testChangedFilePreflightShowsTrashErrorWithoutConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = StorageMapModel(isDemo: false)
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        let node = try XCTUnwrap(model.children.first { $0.name == "File.txt" })
        try Data(repeating: 0x62, count: 65_536).write(to: fixture.file)
        model.requestTrash(node)
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNil(model.pendingTrash)
        XCTAssertEqual(model.errorTitle, "Unable to move item to Trash")
        XCTAssertNotNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testSuccessfulMoveThenRefreshFailureNeverShowsMovedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("Moved file.txt")
        let counter = ScanCounter()
        let model = StorageMapModel(isDemo: false, scanOperation: { configuration, progress in
            if await counter.next() > 1 { throw TestFailure.expected }
            return try await StorageMapScanner().scan(configuration: configuration, progress: progress)
        }, trashOperation: { request in
            try await StorageMapTrash(trashItem: { url in
                try FileManager.default.moveItem(at: url, to: destination)
            }).moveToTrash(request: request)
        })
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        model.requestTrash(try XCTUnwrap(model.children.first { $0.name == "File.txt" }))
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNotNil(model.pendingTrash)
        model.confirmTrash()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.result)
        XCTAssertNil(model.scannedAt)
        XCTAssertTrue(model.children.isEmpty)
        XCTAssertEqual(model.currentURL, fixture.folder)
        XCTAssertEqual(model.errorTitle, "Unable to scan this folder")
        XCTAssertNotNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDemoAllowsConfirmationButNeverExecutesTrash() async throws {
        let probe = TrashProbe()
        let model = StorageMapModel(isDemo: true, trashOperation: { request in await probe.record(request.url) })
        defer { model.shutdown() }
        model.scan()
        try await waitUntil { !model.isBusy }
        let file = try XCTUnwrap(model.children.first { !$0.isDirectory })
        model.requestTrash(file)
        try await waitUntil { !model.isPreparingTrash }
        XCTAssertNotNil(model.pendingTrash)
        model.confirmTrash()
        XCTAssertNotNil(model.pendingTrash)
        XCTAssertFalse(model.isTrashing)
        let count = await probe.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        model.cancelTrash()
    }

    func testRetainedSnapshotDuringScanCannotBeTrashed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = StorageMapModel(isDemo: false)
        defer { model.shutdown() }
        try await scan(model, folder: fixture.folder)
        let file = try XCTUnwrap(model.children.first { !$0.isDirectory })
        model.scan()
        XCTAssertNotNil(model.result)
        XCTAssertFalse(model.canTrash(file))
        model.requestTrash(file)
        XCTAssertFalse(model.isPreparingTrash)
        try await waitUntil { !model.isBusy }
    }

    private func scan(_ model: StorageMapModel, folder: URL) async throws {
        model.setRoot(folder)
        model.scan()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.result)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for model state")
        throw TestFailure.expected
    }

    private func waitForProbe(_ probe: TrashProbe) async throws {
        for _ in 0..<500 {
            if await probe.isWaiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Trash operation")
        throw TestFailure.expected
    }
}

private enum TestFailure: Error { case expected }

private actor TrashProbe {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Error>?
    var isWaiting: Bool { continuation != nil }
    func record(_ url: URL) { count += 1 }
    func suspend(_ url: URL) async throws {
        count += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func fail() {
        continuation?.resume(throwing: TestFailure.expected)
        continuation = nil
    }
}

private actor ScanCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct Fixture {
    let container: URL
    let folder: URL
    let file: URL
    let child: URL
    init() throws {
        container = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacTools-MapTrashModel-\(UUID().uuidString)", isDirectory: true)
        folder = container.appendingPathComponent("Folder", isDirectory: true)
        file = folder.appendingPathComponent("File.txt")
        child = folder.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 8_192).write(to: file)
        try Data(repeating: 0x61, count: 4_096).write(to: child.appendingPathComponent("Nested.txt"))
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
}
