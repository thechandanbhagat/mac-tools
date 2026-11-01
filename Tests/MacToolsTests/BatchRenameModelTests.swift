import Foundation
import XCTest
@testable import MacTools

@MainActor
final class BatchRenameModelTests: XCTestCase {
    func testPreviewIsReadOnlyAndChangingOptionsInvalidatesConfirmation() async throws {
        let fixture = try ModelRenameFixture(); defer { fixture.remove() }
        let model = BatchRenamerModel(isDemo: false); defer { model.shutdown() }
        model.setFiles([fixture.file]); model.options.prefix = "New-"
        try await waitUntil { !model.isBusy }
        XCTAssertTrue(model.canApply); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        model.review(); XCTAssertNotNil(model.pendingPlan)
        model.options.suffix = "-edited"
        XCTAssertNil(model.pendingPlan)
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.plan?.entries[0].destination.lastPathComponent, "New-Original-edited.txt")
        model.review(); model.cancelReview()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testApplyAndUndoUpdateCurrentFiles() async throws {
        let fixture = try ModelRenameFixture(); defer { fixture.remove() }
        let model = BatchRenamerModel(isDemo: false); defer { model.shutdown() }
        model.setFiles([fixture.file]); model.options.prefix = "New-"
        try await waitUntil { !model.isBusy }
        model.review(); model.confirm()
        await model.finishPendingOperation()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.files[0].lastPathComponent, "New-Original.txt")
        XCTAssertNotNil(model.undoReceipt)
        model.reviewUndo(); XCTAssertTrue(model.pendingIsUndo)
        model.confirm(); await model.finishPendingOperation()
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.files[0], fixture.file); XCTAssertNil(model.undoReceipt)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "original contents")
    }

    func testDemoConfirmationNeverRenames() async throws {
        let model = BatchRenamerModel(isDemo: true); defer { model.shutdown() }
        model.loadIfNeeded(); model.options.prefix = "Trip-"
        try await waitUntil { !model.isBusy }
        let original = model.files[0]
        model.review(); XCTAssertNotNil(model.pendingPlan)
        model.confirm()
        XCTAssertFalse(model.isApplying); XCTAssertNotNil(model.pendingPlan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        model.cancelReview(); XCTAssertNil(model.pendingPlan)
    }

    func testConflictBlocksReviewAndLatestPreviewWins() async throws {
        let fixture = try ModelRenameFixture(); defer { fixture.remove() }
        let conflict = fixture.root.appendingPathComponent("New-Original.txt")
        try Data("unrelated".utf8).write(to: conflict)
        let model = BatchRenamerModel(isDemo: false); defer { model.shutdown() }
        model.setFiles([fixture.file]); model.options.prefix = "New-"
        try await waitUntil { !model.isBusy }
        XCTAssertFalse(model.canApply); XCTAssertNotNil(model.previewError)
        model.review(); XCTAssertNil(model.pendingPlan)
        model.options.prefix = "A-"; model.options.prefix = "B-"; model.options.prefix = "Final-"
        try await waitUntil { !model.isBusy }
        XCTAssertEqual(model.plan?.entries[0].destination.lastPathComponent, "Final-Original.txt")
        XCTAssertTrue(model.canApply)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for model"); throw CancellationError()
    }
}
private struct ModelRenameFixture {
    let root = URL(fileURLWithPath: "/private/tmp/MacTools-RenameModelTest-\(UUID().uuidString)", isDirectory: true)
    var file: URL { root.appendingPathComponent("Original.txt") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original contents".utf8).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
