import Foundation
import XCTest
@testable import MacTools

@MainActor
final class DuplicateFinderModelTests: XCTestCase {
    func testDemoScanStartsUnselectedAndAlwaysKeepsOneCopy() async throws {
        let model = DuplicateFinderModel(isDemo: true); defer { model.shutdown() }
        model.loadIfNeeded()
        try await waitUntil { model.hasScanned && !model.isBusy }
        XCTAssertEqual(model.groups.count, 2); XCTAssertTrue(model.selectedIDs.isEmpty)
        let group = model.groups[0]
        model.toggle(group.files[0], in: group)
        XCTAssertEqual(model.selectedIDs.count, 1)
        XCTAssertFalse(model.canSelect(group.files[1], in: group))
        model.toggle(group.files[1], in: group)
        XCTAssertEqual(model.selectedIDs.count, 1)
        model.toggle(group.files[0], in: group)
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }

    func testDemoConfirmationNeverMovesFilesAndCanCancel() async throws {
        let model = DuplicateFinderModel(isDemo: true); defer { model.shutdown() }
        model.loadIfNeeded(); try await waitUntil { model.hasScanned && !model.isBusy }
        let group = model.groups[0], file = model.groups[0].files[0]
        model.toggle(file, in: group); model.review()
        XCTAssertEqual(model.pendingRequest?.files.count, 1)
        model.confirmTrash()
        XCTAssertNotNil(model.pendingRequest); XCTAssertFalse(model.isTrashing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        model.cancelReview(); XCTAssertNil(model.pendingRequest)
    }

    func testRescanInvalidatesSelectionAndPendingConfirmation() async throws {
        let model = DuplicateFinderModel(isDemo: true); defer { model.shutdown() }
        model.loadIfNeeded(); try await waitUntil { model.hasScanned && !model.isBusy }
        let group = model.groups[0]
        model.toggle(group.files[0], in: group); model.review(); model.scan()
        XCTAssertNil(model.pendingRequest); XCTAssertTrue(model.selectedIDs.isEmpty)
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.groups.count, 2)
    }

    func testShutdownRemovesOnlyOwnedDemoFixture() async throws {
        let model = DuplicateFinderModel(isDemo: true)
        model.loadIfNeeded(); try await waitUntil { model.hasScanned && !model.isBusy }
        let root = try XCTUnwrap(model.rootURL)
        model.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for model"); throw CancellationError()
    }
}
