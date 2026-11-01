import Foundation
import XCTest
@testable import MacTools

@MainActor
final class AppUninstallerTests: XCTestCase {
    func testInventoryFindsAppsInUtilitiesAndExcludesOwnAppAndLinks() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let alpha = try fixture.app("Alpha.app", identifier: "com.example.alpha")
        let utility = try fixture.app("Utilities/Utility.app", identifier: "com.example.utility")
        let own = try fixture.app("Mac Tools.app", identifier: "com.example.tools")
        let nested = alpha.appendingPathComponent("Contents/Hidden.app")
        try fixture.makeApp(at: nested, identifier: "com.example.hidden")
        try FileManager.default.createSymbolicLink(at: fixture.apps.appendingPathComponent("Linked.app"), withDestinationURL: utility)
        var config = fixture.configuration
        config.ownApplicationURL = own
        let result = try await AppUninstaller(configuration: config).inventory()
        XCTAssertEqual(Set(result.applications.map(\.url)), [alpha, utility])
        XCTAssertEqual(result.applications.first?.name, "Alpha")
        XCTAssertEqual(result.applications.first?.version, "1.2")
    }

    func testDiscoveryDepthIsBounded() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Top.app")
        _ = try fixture.app("Utilities/Nested.app")
        var config = fixture.configuration
        config.maximumDiscoveryDepth = 0
        let result = try await AppUninstaller(configuration: config).inventory()
        XCTAssertEqual(result.applications.map(\.name), ["Top"])
    }

    func testCloudAndSymlinkApplicationRootsAreExcluded() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let cloud = fixture.root.appendingPathComponent("Library/CloudStorage/Provider/Apps")
        try fixture.makeApp(at: cloud.appendingPathComponent("Cloud.app"))
        let linked = fixture.root.appendingPathComponent("LinkedApps")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.apps)
        var config = fixture.configuration
        config.applicationRoots = [cloud, linked]
        let result = try await AppUninstaller(configuration: config).inventory()
        XCTAssertTrue(result.applications.isEmpty)
        XCTAssertEqual(result.issues.count, 2)
    }

    func testExactRelatedMatchingAndAppOnlyDefaultRequest() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        let cache = try fixture.related("Caches/com.example.alpha/data.bin")
        let preference = try fixture.related("Preferences/com.example.alpha.plist")
        _ = try fixture.related("Application Support/Alpha/data.bin")
        _ = try fixture.related("Caches/com.example.alpha.extra/data.bin")
        _ = try fixture.related("Containers/com.example.alpha/Data/data.bin")
        let (service, inspection) = try await fixture.inspect()
        XCTAssertEqual(Set(inspection.relatedItems.map(\.url)), [cache.deletingLastPathComponent(), preference])
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: [])
        XCTAssertEqual(request.items.map(\.url), [inspection.application.url])
        XCTAssertThrowsError(try service.prepare(inspection: inspection, selectedRelatedIDs: ["/unreviewed"]))
    }

    func testUnsafeBundleIdentifierNeverBuildsRelatedPaths() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app", identifier: "../../outside")
        _ = try fixture.related("Caches/com.example.alpha/data.bin")
        let (_, inspection) = try await fixture.inspect()
        XCTAssertTrue(inspection.relatedItems.isEmpty)
    }

    func testFrameworkLinksAreRecordedWithoutFollowingTheirTargets() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        let payload = app.appendingPathComponent("Contents/Payload.bin")
        let outside = fixture.root.appendingPathComponent("Outside.bin")
        try Data(repeating: 3, count: 2_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("Contents/External"), withDestinationURL: outside)
        let hardlink = app.appendingPathComponent("Contents/Payload-copy.bin")
        try FileManager.default.linkItem(at: payload, to: hardlink)
        let (service, inspection) = try await fixture.inspect()
        let info = app.appendingPathComponent("Contents/Info.plist")
        XCTAssertFalse(inspection.appItem.isPartial)
        XCTAssertEqual(inspection.appItem.byteCount, try FileSafety.snapshot(of: payload).allocatedBytes + FileSafety.snapshot(of: info).allocatedBytes)
        _ = try service.prepare(inspection: inspection, selectedRelatedIDs: [])
    }

    func testAppMetadataChangeAfterInventoryRequiresRefresh() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        let service = fixture.service()
        let inventory = try await service.inventory()
        let application = try XCTUnwrap(inventory.applications.first)
        try fixture.writeInfo(at: app, identifier: "com.example.other")
        do { _ = try await service.inspect(application: application); XCTFail("Changed metadata must be refused") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testPartialItemsCannotBeConfirmed() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        var config = fixture.configuration
        config.maximumEntries = 3
        let service = AppUninstaller(configuration: config, isRunning: { _, _ in false })
        let inventory = try await service.inventory()
        let application = try XCTUnwrap(inventory.applications.first)
        let inspection = try await service.inspect(application: application)
        XCTAssertTrue(inspection.appItem.isPartial)
        XCTAssertFalse(inspection.issues.isEmpty)
        XCTAssertThrowsError(try service.prepare(inspection: inspection, selectedRelatedIDs: []))
    }

    func testDeepAppChangeAfterReviewPreventsEveryMove() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        _ = try fixture.related("Caches/com.example.alpha/data.bin")
        let calls = UninstallCalls()
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: Set(inspection.relatedItems.map(\.id)))
        try Data(repeating: 7, count: 8_192).write(to: app.appendingPathComponent("Contents/Payload.bin"))
        let result = await service.moveToTrash(request: request)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertTrue(result.movedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testChangedRelatedItemPreventsAppMove() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        let cache = try fixture.related("Caches/com.example.alpha/data.bin")
        let calls = UninstallCalls()
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: Set(inspection.relatedItems.map(\.id)))
        try Data(repeating: 8, count: 4_096).write(to: cache)
        let result = await service.moveToTrash(request: request)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testReplacedAncestorWithSameAppIdentityIsRefused() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        let calls = UninstallCalls()
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: [])
        let old = fixture.root.appendingPathComponent("OldApplications")
        try FileManager.default.moveItem(at: fixture.apps, to: old)
        try FileManager.default.createDirectory(at: fixture.apps, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: old.appendingPathComponent("Alpha.app"), to: app)
        let result = await service.moveToTrash(request: request)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testRunningAppIsBlockedAtReviewAndExecution() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        let calls = UninstallCalls()
        let running = UninstallRunningState()
        let service = AppUninstaller(configuration: fixture.configuration, trashItem: calls.record, isRunning: { _, _ in await running.value })
        let inventory = try await service.inventory()
        let app = try XCTUnwrap(inventory.applications.first)
        await running.set(true)
        let runningInspection = try await service.inspect(application: app)
        XCTAssertTrue(runningInspection.isRunning)
        XCTAssertThrowsError(try service.prepare(inspection: runningInspection, selectedRelatedIDs: []))
        await running.set(false)
        let inspection = try await service.inspect(application: app)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: [])
        await running.set(true)
        let result = await service.moveToTrash(request: request)
        XCTAssertTrue(calls.urls.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testAppTrashFailureLeavesAllRelatedItemsUntouched() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        _ = try fixture.related("Caches/com.example.alpha/data.bin")
        let calls = UninstallCalls(failPaths: [app.path])
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: Set(inspection.relatedItems.map(\.id)))
        let result = await service.moveToTrash(request: request)
        XCTAssertEqual(calls.urls, [app])
        XCTAssertTrue(result.movedItems.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testRelatedFailuresAreReportedWithSuccessfulMoves() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        let cache = try fixture.related("Caches/com.example.alpha/data.bin").deletingLastPathComponent()
        let preference = try fixture.related("Preferences/com.example.alpha.plist")
        let calls = UninstallCalls(failPaths: [cache.path])
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: Set(inspection.relatedItems.map(\.id)))
        let result = await service.moveToTrash(request: request)
        XCTAssertEqual(result.movedItems.map(\.url), [app, preference])
        XCTAssertEqual(result.failures.map(\.item.url), [cache])
        XCTAssertFalse(result.isCancelled)
    }

    func testSuccessfulExecutionMovesOnlyExplicitlySelectedFixtureItems() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        let app = try fixture.app("Alpha.app")
        let cache = try fixture.related("Caches/com.example.alpha/data.bin").deletingLastPathComponent()
        let preference = try fixture.related("Preferences/com.example.alpha.plist")
        let destination = fixture.root.appendingPathComponent("Moved")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let (service, inspection) = try await fixture.inspect(trash: { url in
            try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        })
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: [cache.path])
        let result = await service.moveToTrash(request: request)
        XCTAssertEqual(result.movedItems.map(\.url), [app, cache])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preference.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Alpha.app").path))
    }

    func testCancelledExecutionDoesNotCallTrash() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        let calls = UninstallCalls()
        let (service, inspection) = try await fixture.inspect(trash: calls.record)
        let request = try service.prepare(inspection: inspection, selectedRelatedIDs: [])
        let task = Task { await service.moveToTrash(request: request) }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.isCancelled)
        XCTAssertTrue(calls.urls.isEmpty)
    }

    func testRelatedSymlinkIsSkippedAndReported() async throws {
        let fixture = try UninstallFixture()
        defer { fixture.remove() }
        _ = try fixture.app("Alpha.app")
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let caches = fixture.library.appendingPathComponent("Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("com.example.alpha"), withDestinationURL: outside)
        let (_, inspection) = try await fixture.inspect()
        XCTAssertTrue(inspection.relatedItems.isEmpty)
        XCTAssertEqual(inspection.issues.count, 1)
    }
}

private struct UninstallFixture {
    let root: URL
    var apps: URL { root.appendingPathComponent("Applications") }
    var library: URL { root.appendingPathComponent("Library") }
    var configuration: AppUninstallerConfiguration {
        AppUninstallerConfiguration(applicationRoots: [apps], libraryURL: library, ownApplicationURL: nil)
    }
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/MacTools-Uninstaller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }
    func app(_ path: String, identifier: String = "com.example.alpha") throws -> URL {
        let url = apps.appendingPathComponent(path, isDirectory: true)
        try makeApp(at: url, identifier: identifier)
        return url
    }
    func makeApp(at url: URL, identifier: String = "com.example.alpha") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try writeInfo(at: url, identifier: identifier)
        try Data(repeating: 3, count: 8_192).write(to: url.appendingPathComponent("Contents/Payload.bin"))
    }
    func writeInfo(at url: URL, identifier: String) throws {
        let info = ["CFBundleIdentifier": identifier, "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    func related(_ path: String) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 4, count: 8_192).write(to: url)
        return url
    }
    func service(trash: @escaping AppUninstaller.TrashHandler = { _ in }) -> AppUninstaller {
        AppUninstaller(configuration: configuration, trashItem: trash, isRunning: { _, _ in false })
    }
    func inspect(trash: @escaping AppUninstaller.TrashHandler = { _ in }) async throws -> (AppUninstaller, AppUninstallerInspection) {
        let service = service(trash: trash)
        guard let app = try await service.inventory().applications.first else { throw FileSafetyError.refused("Fixture app missing") }
        return (service, try await service.inspect(application: app))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class UninstallCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    let failPaths: Set<String>
    init(failPaths: Set<String> = []) { self.failPaths = failPaths }
    var urls: [URL] { lock.withLock { recorded } }
    func record(_ url: URL) throws {
        lock.withLock { recorded.append(url) }
        if failPaths.contains(url.path) { throw FileSafetyError.refused("Fixture move failed") }
    }
}

private actor UninstallRunningState {
    var value = false
    func set(_ value: Bool) { self.value = value }
}
