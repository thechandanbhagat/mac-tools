import Foundation
import XCTest
@testable import MacTools

@MainActor
final class StorageMapModelTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/MapSelection", isDirectory: true)

    func testChosenFolderKeepsCanonicalPrivatePath() {
        let model = StorageMapModel(isDemo: false)
        model.setRoot(root)
        XCTAssertEqual(model.rootURL.path, "/private/tmp/MapSelection")
        XCTAssertEqual(model.currentURL, root)
        XCTAssertFalse(model.hasLocation)
    }

    func testEnteringAndRefreshingFolderReadCurrentFiles() async throws {
        let folder = try makeFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let first = child.appendingPathComponent("first.bin")
        try Data(repeating: 1, count: 8_192).write(to: first)
        let model = StorageMapModel(isDemo: false)
        defer { model.shutdown() }
        model.setRoot(folder)
        model.scan()
        try await waitForIdle(model)
        let initialChild = try XCTUnwrap(model.children.first)
        let second = child.appendingPathComponent("second.bin")
        try Data(repeating: 2, count: 16_384).write(to: second)

        model.navigate(to: initialChild)
        XCTAssertTrue(model.isScanning)
        XCTAssertNil(model.result)
        XCTAssertNil(model.scannedAt)
        XCTAssertEqual(model.currentURL, child)
        try await waitForIdle(model)
        let expected = try FileSafety.snapshot(of: first).allocatedBytes + FileSafety.snapshot(of: second).allocatedBytes
        XCTAssertEqual(model.currentTotal, expected)
        XCTAssertEqual(model.children.count, 2)
        XCTAssertEqual(model.rootURL, folder)
        XCTAssertEqual(model.navigationIDs, [folder.path, child.path])
        XCTAssertNil(model.result?.nodes[folder.path])

        try FileManager.default.removeItem(at: first)
        model.scan()
        XCTAssertEqual(model.currentTotal, expected)
        try await waitForIdle(model)
        XCTAssertEqual(model.currentTotal, try FileSafety.snapshot(of: second).allocatedBytes)
        XCTAssertEqual(model.children.map(\.name), ["second.bin"])
        XCTAssertEqual(model.navigationIDs, [folder.path, child.path])
    }

    func testSubfolderGetsIndependentHardLinkAttributionAndFreshBudget() async throws {
        let folder = try makeFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstFolder = folder.appendingPathComponent("a", isDirectory: true)
        let child = folder.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let original = firstFolder.appendingPathComponent("original.bin")
        try Data(repeating: 1, count: 8_192).write(to: original)
        try FileManager.default.linkItem(at: original, to: child.appendingPathComponent("alias.bin"))
        let model = StorageMapModel(isDemo: false)
        defer { model.shutdown() }
        model.setRoot(folder)
        model.scan()
        try await waitForIdle(model)
        let sharedChild = try XCTUnwrap(model.children.first { $0.url == child })
        XCTAssertEqual(sharedChild.byteCount, 0)
        XCTAssertEqual(sharedChild.sharedFileCount, 1)
        model.navigate(to: sharedChild)
        try await waitForIdle(model)
        XCTAssertEqual(model.currentTotal, try FileSafety.snapshot(of: original).allocatedBytes)
        XCTAssertEqual(model.currentNode?.sharedFileCount, 0)
        XCTAssertNil(model.result?.nodes[folder.path])

        let limited = StorageMapModel(isDemo: false, scanOperation: { configuration, progress in
            var config = configuration
            config.maximumDepth = 1
            return try await StorageMapScanner().scan(configuration: config, progress: progress)
        })
        defer { limited.shutdown() }
        limited.setRoot(folder)
        limited.scan()
        try await waitForIdle(limited)
        XCTAssertTrue(limited.currentNode?.isPartial == true)
        let limitedChild = try XCTUnwrap(limited.children.first { $0.url == child })
        XCTAssertTrue(limitedChild.isPartial)
        limited.navigate(to: limitedChild)
        try await waitForIdle(limited)
        XCTAssertFalse(limited.currentNode?.isPartial == true)
        XCTAssertGreaterThan(limited.currentTotal, 0)
    }

    func testBackAndBreadcrumbsStartFreshScansWithoutLosingTrail() async throws {
        let harness = ScanHarness()
        let model = makeModel(harness)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        let nested = child.appendingPathComponent("Nested", isDirectory: true)
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        await harness.succeed(0, snapshot(root, children: [child], bytes: 100))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 2)
        await harness.succeed(1, snapshot(child, children: [nested], bytes: 200))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 3)
        XCTAssertEqual(model.navigationIDs, [root.path, child.path, nested.path])
        await harness.succeed(2, snapshot(nested, bytes: 300))
        try await waitForIdle(model)

        model.goBack()
        try await waitForRequests(harness, 4)
        let backTarget = await harness.configuration(3)
        XCTAssertEqual(backTarget.root, child)
        XCTAssertEqual(model.navigationIDs, [root.path, child.path])
        XCTAssertNil(model.result)
        await harness.succeed(3, snapshot(child, bytes: 400))
        try await waitForIdle(model)
        XCTAssertEqual(model.currentTotal, 400)

        model.navigate(to: try XCTUnwrap(model.breadcrumbs.first))
        try await waitForRequests(harness, 5)
        let breadcrumbTarget = await harness.configuration(4)
        XCTAssertEqual(breadcrumbTarget.root, root)
        await harness.succeed(4, snapshot(root, bytes: 500))
        try await waitForIdle(model)
        XCTAssertEqual(model.navigationIDs, [root.path])
        XCTAssertEqual(model.currentTotal, 500)
    }

    func testBackSupersedesChildScanAndIgnoresOldCompletionAndProgress() async throws {
        let harness = ScanHarness()
        let model = makeModel(harness)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        await harness.succeed(0, snapshot(root, children: [child]))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 2)
        model.goBack()
        try await waitForRequests(harness, 3)
        await harness.emit(1, count: 999)
        await harness.succeed(1, snapshot(child, bytes: 999))
        try await drainCallbacks()
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.currentURL, root)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.progressCount, 0)
        await harness.emit(2, count: 7)
        try await drainCallbacks()
        XCTAssertEqual(model.progressCount, 7)
        await harness.succeed(2, snapshot(root, bytes: 700))
        try await waitForIdle(model)
        await harness.emit(1, count: 888)
        await harness.emit(2, count: 888)
        try await drainCallbacks()
        XCTAssertEqual(model.currentTotal, 700)
        XCTAssertEqual(model.progressCount, 7)
    }

    func testManualRefreshCancellationAndFailureRetainSnapshotAndTime() async throws {
        let harness = ScanHarness()
        let model = makeModel(harness)
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        await harness.succeed(0, snapshot(root, bytes: 100))
        try await waitForIdle(model)
        let scannedAt = model.scannedAt

        model.scan()
        try await waitForRequests(harness, 2)
        model.cancel()
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.currentTotal, 100)
        XCTAssertEqual(model.scannedAt, scannedAt)
        XCTAssertNotNil(model.notice)
        await harness.emit(1, count: 999)
        await harness.succeed(1, snapshot(root, bytes: 999))
        try await drainCallbacks()
        XCTAssertEqual(model.currentTotal, 100)
        XCTAssertEqual(model.progressCount, 0)

        model.scan()
        try await waitForRequests(harness, 3)
        await harness.fail(2)
        try await waitForIdle(model)
        XCTAssertEqual(model.currentTotal, 100)
        XCTAssertEqual(model.scannedAt, scannedAt)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.hasLocation)
    }

    func testCancelledChildAndFailedRetryKeepLocationAndAllowRootNavigation() async throws {
        let harness = ScanHarness()
        let model = makeModel(harness)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        await harness.succeed(0, snapshot(root, children: [child]))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 2)
        model.cancel()
        XCTAssertNil(model.result)
        XCTAssertNil(model.scannedAt)
        XCTAssertEqual(model.navigationIDs, [root.path, child.path])
        model.scan()
        try await waitForRequests(harness, 3)
        let retryTarget = await harness.configuration(2)
        XCTAssertEqual(retryTarget.root, child)
        await harness.fail(1)
        try await drainCallbacks()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isScanning)
        await harness.fail(2)
        try await waitForIdle(model)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.currentURL, child)
        XCTAssertNil(model.result)
        model.goToRoot()
        try await waitForRequests(harness, 4)
        XCTAssertEqual(model.navigationIDs, [root.path])
        await harness.succeed(3, snapshot(root))
        try await waitForIdle(model)
        XCTAssertNil(model.error)
    }

    func testHiddenOptionRescansCurrentFolderAndClearsIncompatibleSnapshot() async throws {
        let harness = ScanHarness()
        let model = makeModel(harness)
        let child = root.appendingPathComponent("Child", isDirectory: true)
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        await harness.succeed(0, snapshot(root, children: [child]))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 2)
        await harness.succeed(1, snapshot(child, bytes: 100))
        try await waitForIdle(model)
        model.includeHidden = false
        try await waitForRequests(harness, 3)
        let target = await harness.configuration(2)
        XCTAssertEqual(target.root, child)
        XCTAssertFalse(target.includeHidden)
        XCTAssertEqual(model.navigationIDs, [root.path, child.path])
        XCTAssertNil(model.result)
        XCTAssertNil(model.scannedAt)
        model.cancel()
        await harness.fail(2)
        try await drainCallbacks()
        XCTAssertNil(model.result)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentURL, child)
    }

    func testDeletedChildRetainsBackRoute() async throws {
        let folder = try makeFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let child = folder.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let model = StorageMapModel(isDemo: false)
        defer { model.shutdown() }
        model.setRoot(folder)
        model.scan()
        try await waitForIdle(model)
        let node = try XCTUnwrap(model.children.first)
        try FileManager.default.removeItem(at: child)
        model.navigate(to: node)
        try await waitForIdle(model)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.currentURL, child)
        XCTAssertEqual(model.navigationIDs, [folder.path, child.path])
        XCTAssertNil(model.result)
        model.goBack()
        try await waitForIdle(model)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentURL, folder)
        XCTAssertTrue(model.children.isEmpty)
    }

    func testDemoSubfolderRefreshKeepsDemoLocation() async throws {
        let harness = ScanHarness()
        let model = StorageMapModel(isDemo: true, scanOperation: { configuration, progress in
            try await harness.scan(configuration, progress: progress)
        })
        defer { model.shutdown() }
        model.scan()
        try await waitForRequests(harness, 1)
        let demoConfig = await harness.configuration(0)
        let demoRoot = demoConfig.root
        let child = demoRoot.appendingPathComponent("Projects", isDirectory: true)
        XCTAssertTrue(demoRoot.lastPathComponent.hasPrefix("MacTools-MapDemo-"))
        await harness.succeed(0, snapshot(demoRoot, children: [child]))
        try await waitForIdle(model)
        model.navigate(to: try XCTUnwrap(model.children.first))
        try await waitForRequests(harness, 2)
        await harness.succeed(1, snapshot(child))
        try await waitForIdle(model)
        model.scan()
        try await waitForRequests(harness, 3)
        let refreshConfig = await harness.configuration(2)
        XCTAssertEqual(refreshConfig.root, child)
        XCTAssertEqual(model.rootURL, demoRoot)
        XCTAssertEqual(model.navigationIDs, [demoRoot.path, child.path])
        await harness.succeed(2, snapshot(child))
        try await waitForIdle(model)
    }

    private func makeModel(_ harness: ScanHarness) -> StorageMapModel {
        let model = StorageMapModel(isDemo: false, scanOperation: { configuration, progress in
            try await harness.scan(configuration, progress: progress)
        })
        model.setRoot(root)
        return model
    }

    private func makeFixture() throws -> URL {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacTools-MapModelTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func snapshot(_ root: URL, children: [URL] = [], bytes: Int64 = 10) -> StorageMapResult {
        let rootNode = StorageMapNode(
            id: root.path, url: root, name: root.lastPathComponent, isDirectory: true,
            isPackage: false, byteCount: bytes, fileCount: children.count,
            childIDs: children.map(\.path), isPartial: false
        )
        var nodes = [root.path: rootNode]
        for child in children {
            nodes[child.path] = StorageMapNode(
                id: child.path, url: child, name: child.lastPathComponent, isDirectory: true,
                isPackage: false, byteCount: bytes, fileCount: 0, childIDs: [], isPartial: false
            )
        }
        return StorageMapResult(rootID: root.path, nodes: nodes, issues: [], enumeratedCount: children.count, inspectedCount: children.count, reachedLimit: false)
    }

    private func waitForRequests(_ harness: ScanHarness, _ count: Int) async throws {
        for _ in 0..<500 {
            if await harness.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected \(count) scan requests")
        throw ModelTestError.timeout
    }

    private func waitForIdle(_ model: StorageMapModel) async throws {
        for _ in 0..<500 {
            if !model.isScanning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scan did not finish")
        throw ModelTestError.timeout
    }

    private func drainCallbacks() async throws {
        try await Task.sleep(for: .milliseconds(30))
    }
}

private enum ModelTestError: Error { case failed, timeout }

/// Deliberately ignores task cancellation so tests exercise late callbacks from
/// superseded scans, rather than relying on the filesystem scanner's cooperation.
private actor ScanHarness {
    private struct Request {
        let configuration: StorageMapConfiguration
        let progress: @Sendable (ScanProgress) -> Void
        var continuation: CheckedContinuation<StorageMapResult, any Error>?
    }
    private var requests: [Request] = []
    var count: Int { requests.count }

    func scan(_ configuration: StorageMapConfiguration, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> StorageMapResult {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(Request(configuration: configuration, progress: progress, continuation: continuation))
        }
    }

    func configuration(_ index: Int) -> StorageMapConfiguration { requests[index].configuration }

    func emit(_ index: Int, count: Int) {
        requests[index].progress(ScanProgress(inspectedCount: count, discoveredBytes: 0, currentPath: "progress-\(count)"))
    }

    func succeed(_ index: Int, _ result: StorageMapResult) {
        requests[index].continuation?.resume(returning: result)
        requests[index].continuation = nil
    }

    func fail(_ index: Int) {
        requests[index].continuation?.resume(throwing: ModelTestError.failed)
        requests[index].continuation = nil
    }
}
