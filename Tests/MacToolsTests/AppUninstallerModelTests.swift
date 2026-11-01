import Darwin
import Foundation
import XCTest
@testable import MacTools

@MainActor
final class AppUninstallerModelTests: XCTestCase {
    func testLoadSelectAndSearchKeepRelatedItemsUnchecked() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let model = AppUninstallerModel(isDemo: false, service: fixture.service())
        defer { model.shutdown() }
        try await load(model)
        XCTAssertEqual(model.applications.map(\.name), ["Alpha", "Beta"])
        try await select("Alpha", in: model)
        let inspection = try XCTUnwrap(model.inspection)
        XCTAssertEqual(inspection.application.name, "Alpha")
        XCTAssertEqual(inspection.relatedItems.count, 3)
        XCTAssertTrue(model.selectedRelatedIDs.isEmpty)
        XCTAssertEqual(model.selectedItems.map(\.id), [inspection.appItem.id])
        XCTAssertEqual(model.selectedBytes, inspection.appItem.byteCount)
        XCTAssertTrue(model.canReview)
        model.query = "COM.EXAMPLE.ALPHA"
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Alpha"])
        model.query = "beta"
        XCTAssertEqual(model.filteredApplications.map(\.name), ["Beta"])
        model.loadIfNeeded()
        XCTAssertEqual(model.inspection?.application.name, "Alpha")
        XCTAssertFalse(model.isBusy)
    }

    func testReviewIncludesOnlyAppAndExplicitlySelectedRelatedItems() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let model = AppUninstallerModel(isDemo: false, service: fixture.service())
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        let inspection = try XCTUnwrap(model.inspection)
        let selected = try XCTUnwrap(inspection.relatedItems.first)
        let unchecked = inspection.relatedItems[1]
        model.toggleRelated(selected)
        model.toggleRelated(unchecked)
        model.toggleRelated(unchecked)
        XCTAssertEqual(model.selectedRelatedIDs, [selected.id])
        model.review()
        let request = try XCTUnwrap(model.pendingRequest)
        XCTAssertEqual(request.items.map(\.id), [inspection.appItem.id, selected.id])
        XCTAssertEqual(request.byteCount, inspection.appItem.byteCount + selected.byteCount)
        XCTAssertFalse(model.canReview)
        model.toggleRelated(unchecked)
        XCTAssertEqual(model.selectedRelatedIDs, [selected.id])
        XCTAssertEqual(model.pendingRequest?.items.map(\.id), request.items.map(\.id))
    }

    func testCancelNeverInvokesTrash() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let calls = UninstallerModelCalls()
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(trashItem: calls.record))
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        model.review()
        XCTAssertNotNil(model.pendingRequest)
        XCTAssertTrue(calls.urls.isEmpty)
        model.cancelReview()
        model.confirmUninstall()
        XCTAssertNil(model.pendingRequest)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.alpha.path))
    }

    func testDemoCanReviewButCannotExecuteTrash() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let calls = UninstallerModelCalls()
        let model = AppUninstallerModel(isDemo: true, service: fixture.service(trashItem: calls.record))
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        model.review()
        XCTAssertNotNil(model.pendingRequest)
        model.confirmUninstall()
        XCTAssertNotNil(model.pendingRequest)
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.alpha.path))
    }

    func testConfirmedMoveRemovesAppAndOnlySelectedRelatedDataThenUpdatesList() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let calls = UninstallerModelCalls()
        let service = fixture.service { url in
            calls.record(url)
            try fixture.moveToFixtureDestination(url)
        }
        let model = AppUninstallerModel(isDemo: false, service: service)
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        let inspection = try XCTUnwrap(model.inspection)
        let selected = try XCTUnwrap(inspection.relatedItems.first)
        let unchecked = Array(inspection.relatedItems.dropFirst())
        model.toggleRelated(selected)
        model.review()
        model.confirmUninstall()
        try await waitUntil { !model.isBusy }
        XCTAssertNil(model.error)
        XCTAssertNil(model.pendingRequest)
        XCTAssertNil(model.inspection)
        XCTAssertNil(model.selectedApplication)
        XCTAssertTrue(model.selectedRelatedIDs.isEmpty)
        XCTAssertEqual(model.applications.map(\.name), ["Beta"])
        XCTAssertEqual(calls.urls.map(\.path), [fixture.alpha.path, selected.url.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.alpha.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination(for: fixture.alpha).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination(for: selected.url).path))
        XCTAssertTrue(unchecked.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(model.notice, "Moved 2 items to Trash.")
        model.refresh()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.applications.map(\.name), ["Beta"])
    }

    func testFailedAppMoveLeavesOptionalDataAndAppInList() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let calls = UninstallerModelCalls()
        let model = AppUninstallerModel(isDemo: false, service: fixture.service { url in
            calls.record(url)
            throw NSError(domain: "AppUninstallerModelFixture", code: 8)
        })
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        let related = try XCTUnwrap(model.inspection).relatedItems
        for item in related { model.toggleRelated(item) }
        model.review()
        model.confirmUninstall()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(calls.urls.map(\.path), [fixture.alpha.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.alpha.path))
        XCTAssertTrue(related.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(model.applications.map(\.name), ["Alpha", "Beta"])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.issues.isEmpty)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.canReview)
    }

    func testNewSelectionAndRefreshInvalidatePendingReview() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let calls = UninstallerModelCalls()
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(trashItem: calls.record))
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        model.review()
        XCTAssertNotNil(model.pendingRequest)
        try await select("Beta", in: model)
        XCTAssertNil(model.pendingRequest)
        model.confirmUninstall()
        XCTAssertTrue(calls.urls.isEmpty)
        model.review()
        XCTAssertNotNil(model.pendingRequest)
        model.refresh()
        XCTAssertNil(model.pendingRequest)
        model.confirmUninstall()
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertNil(model.inspection)
        XCTAssertNil(model.selectedApplication)
    }

    func testStaleInspectionCannotReplaceNewSelection() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let running = UninstallerModelRunningProbe()
        await running.block(applicationName: "Alpha")
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(isRunning: { url, _ in await running.check(url) }))
        defer { model.shutdown() }
        try await load(model)
        model.select(try XCTUnwrap(model.applications.first { $0.name == "Alpha" }))
        try await waitForGate(running)
        try await select("Beta", in: model)
        XCTAssertEqual(model.inspection?.application.name, "Beta")
        await running.release()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.selectedApplication?.name, "Beta")
        XCTAssertEqual(model.inspection?.application.name, "Beta")
        XCTAssertNil(model.error)
    }

    func testCancelInspectionIgnoresLateCompletion() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let running = UninstallerModelRunningProbe()
        await running.block(applicationName: "Alpha")
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(isRunning: { url, _ in await running.check(url) }))
        defer { model.shutdown() }
        try await load(model)
        model.select(try XCTUnwrap(model.applications.first { $0.name == "Alpha" }))
        try await waitForGate(running)
        model.cancelScan()
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.inspection)
        await running.release()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(model.inspection)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.notice, "Scan cancelled.")
    }

    func testRunningAppCannotBeReviewedAndStartAfterReviewPreventsMove() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let running = UninstallerModelRunningProbe()
        let calls = UninstallerModelCalls()
        await running.setRunning(true)
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(trashItem: calls.record, isRunning: { url, _ in await running.check(url) }))
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        XCTAssertTrue(try XCTUnwrap(model.inspection).isRunning)
        XCTAssertFalse(model.canReview)
        model.review()
        XCTAssertNil(model.pendingRequest)
        await running.setRunning(false)
        try await select("Alpha", in: model)
        model.review()
        XCTAssertNotNil(model.pendingRequest)
        await running.setRunning(true)
        model.confirmUninstall()
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.applications.contains { $0.name == "Alpha" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.alpha.path))
    }

    func testBusyUninstallRejectsSelectionRefreshAndDuplicateConfirmation() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let running = UninstallerModelRunningProbe()
        let calls = UninstallerModelCalls()
        let model = AppUninstallerModel(isDemo: false, service: fixture.service(trashItem: calls.record, isRunning: { url, _ in await running.check(url) }))
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        let related = try XCTUnwrap(model.inspection?.relatedItems.first)
        model.review()
        await running.block(applicationName: "Alpha")
        model.confirmUninstall()
        try await waitForGate(running)
        XCTAssertTrue(model.isUninstalling)
        model.select(try XCTUnwrap(model.applications.first { $0.name == "Beta" }))
        model.refresh()
        model.toggleRelated(related)
        model.review()
        model.confirmUninstall()
        model.cancelReview()
        model.cancelScan()
        XCTAssertTrue(model.isUninstalling)
        XCTAssertEqual(model.selectedApplication?.name, "Alpha")
        XCTAssertTrue(model.selectedRelatedIDs.isEmpty)
        XCTAssertNil(model.pendingRequest)
        await running.release()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(calls.urls.map(\.path), [fixture.alpha.path])
        XCTAssertNil(model.error)
    }

    func testPartialRelatedItemCannotBeSelectedWhileAppRemainsReviewable() async throws {
        let fixture = try UninstallerModelFixture()
        defer { fixture.remove() }
        let cache = fixture.library.appendingPathComponent("Caches/com.example.alpha")
        XCTAssertEqual(mkfifo(cache.appendingPathComponent("pipe").path, mode_t(0o600)), 0)
        let model = AppUninstallerModel(isDemo: false, service: fixture.service())
        defer { model.shutdown() }
        try await load(model)
        try await select("Alpha", in: model)
        let partial = try XCTUnwrap(model.inspection?.relatedItems.first { $0.isPartial })
        model.toggleRelated(partial)
        XCTAssertTrue(model.selectedRelatedIDs.isEmpty)
        XCTAssertTrue(model.canReview)
        XCTAssertFalse(model.allIssues.isEmpty)
        model.review()
        XCTAssertEqual(model.pendingRequest?.items.count, 1)
    }

    private func load(_ model: AppUninstallerModel) async throws {
        model.loadIfNeeded()
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.error)
    }

    private func select(_ name: String, in model: AppUninstallerModel) async throws {
        model.select(try XCTUnwrap(model.applications.first { $0.name == name }))
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.inspection?.application.name, name)
        XCTAssertNil(model.error)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for uninstaller model state")
        throw UninstallerModelTestFailure.timeout
    }

    private func waitForGate(_ gate: UninstallerModelRunningProbe) async throws {
        for _ in 0..<500 {
            if await gate.isWaiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for running-app check")
        throw UninstallerModelTestFailure.timeout
    }
}

private enum UninstallerModelTestFailure: Error { case timeout }

private final class UninstallerModelCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    var urls: [URL] { lock.withLock { recorded } }
    func record(_ url: URL) { lock.withLock { recorded.append(url) } }
}

private actor UninstallerModelRunningProbe {
    private var running = false
    private var blockedName: String?
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func setRunning(_ value: Bool) { running = value }
    func block(applicationName: String) { blockedName = applicationName }
    func check(_ url: URL) async -> Bool {
        if url.deletingPathExtension().lastPathComponent == blockedName {
            await withCheckedContinuation { continuation = $0 }
        }
        return running
    }
    func release() {
        blockedName = nil
        continuation?.resume()
        continuation = nil
    }
}

private struct UninstallerModelFixture: Sendable {
    let root: URL
    let applications: URL
    let library: URL
    let alpha: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("MacTools-UninstallerModel-\(UUID().uuidString)", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        library = root.appendingPathComponent("Library", isDirectory: true)
        alpha = applications.appendingPathComponent("Alpha.app", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for name in ["Alpha", "Beta"] {
            let identifier = "com.example.\(name.lowercased())"
            let contents = applications.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info = ["CFBundleName": name, "CFBundleIdentifier": identifier,
                        "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try Data(repeating: 0x61, count: 8_192).write(to: contents.appendingPathComponent("Resources/Data.bin"))
            for location in ["Caches/\(identifier)/Cache.bin", "Preferences/\(identifier).plist", "Application Support/\(identifier)/Settings.bin"] {
                let file = library.appendingPathComponent(location)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x62, count: 4_096).write(to: file)
            }
        }
    }

    func service(
        trashItem: @escaping AppUninstaller.TrashHandler = { _ in },
        isRunning: @escaping AppUninstaller.RunningCheck = { _, _ in false }
    ) -> AppUninstaller {
        AppUninstaller(configuration: .init(applicationRoots: [applications], libraryURL: library, ownApplicationURL: nil),
                       trashItem: trashItem, isRunning: isRunning)
    }

    func destination(for url: URL) -> URL {
        root.appendingPathComponent("Moved", isDirectory: true)
            .appendingPathComponent(String(url.path.dropFirst(root.path.count + 1)))
    }

    func moveToFixtureDestination(_ url: URL) throws {
        let destination = destination(for: url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
