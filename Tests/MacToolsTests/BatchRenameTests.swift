import Darwin
import Foundation
import XCTest
@testable import MacTools

final class BatchRenameTests: XCTestCase, @unchecked Sendable {
    func testPreviewCombinesPatternAndPreservesExtension() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let b = try fixture.file("Photo B.JPG"), a = try fixture.file("Photo A.JPG")
        var options = BatchRenameOptions()
        options.find = "Photo"; options.replacement = "Trip"; options.prefix = "2026-"; options.suffix = "-edited"
        options.numbering = true; options.startNumber = 7
        let plan = try BatchRenamer().preview(files: [b, a], options: options)
        XCTAssertEqual(plan.entries.map { $0.destination.lastPathComponent }, ["2026-Trip A-edited_7.JPG", "2026-Trip B-edited_8.JPG"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testDateAndExtensionOption() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let url = try fixture.file("Photo.JPG")
        var options = BatchRenameOptions(); options.includeDate = true; options.preserveExtension = false
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try BatchRenamer().preview(files: [url], options: options, date: date)
        XCTAssertTrue(plan.entries[0].destination.lastPathComponent.hasPrefix("Photo.JPG_2023-11-"))
    }

    func testPreviewRejectsMultipleHardLinksToSameFile() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let original = try fixture.file("Original.txt")
        let linked = fixture.root.appendingPathComponent("Linked.txt")
        try FileManager.default.linkItem(at: original, to: linked)
        var options = BatchRenameOptions(); options.prefix = "New-"
        XCTAssertThrowsError(try BatchRenamer().preview(files: [original, linked], options: options)) { error in
            XCTAssertTrue(error.localizedDescription.contains("one hard link"))
        }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "contents")
        XCTAssertEqual(try String(contentsOf: linked, encoding: .utf8), "contents")
        XCTAssertEqual(try BatchRenamer().preview(files: [original], options: options).changes.count, 1)
    }

    func testNoChangePlanCannotApply() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let url = try fixture.file("A.txt")
        let plan = try BatchRenamer().preview(files: [url], options: BatchRenameOptions())
        XCTAssertTrue(plan.changes.isEmpty)
        do { _ = try await BatchRenamer().apply(plan); XCTFail("Expected refusal") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRejectsInvalidNamesAndNumberOverflow() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let url = try fixture.file("A.txt")
        for prefix in ["/", ".", ":", "\0", String(repeating: "x", count: 256)] {
            var options = BatchRenameOptions(); options.prefix = prefix
            XCTAssertThrowsError(try BatchRenamer().preview(files: [url], options: options))
        }
        var options = BatchRenameOptions(); options.startNumber = Int.max
        XCTAssertThrowsError(try BatchRenamer().preview(files: [url], options: options))
    }

    func testRejectsExistingDestinationAndDuplicateTargets() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt"), b = try fixture.file("B.txt")
        var options = BatchRenameOptions(); options.find = "A"; options.replacement = "B"
        XCTAssertThrowsError(try BatchRenamer().preview(files: [a], options: options))
        XCTAssertThrowsError(try BatchRenamer().preview(files: [a, b], options: options))
    }

    func testRejectsFoldersLinksCloudAndPackageContents() throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let source = try fixture.file("A.txt")
        let link = fixture.root.appendingPathComponent("Link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let cloud = try fixture.file("CloudStorage/Provider/A.txt")
        let package = try fixture.file("Example.app/Contents/A.txt")
        for url in [fixture.root, link, cloud, package] {
            XCTAssertThrowsError(try BatchRenamer().preview(files: [url], options: BatchRenameOptions()))
        }
    }

    func testApplyAndUndoRestoresNamesAndContents() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt", contents: "first"), b = try fixture.file("B.txt", contents: "second")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let service = BatchRenamer()
        let plan = try service.preview(files: [a, b], options: options)
        let receipt = try await service.apply(plan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: plan.entries[0].destination, encoding: .utf8), "first")
        _ = try await service.apply(receipt.undoPlan)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "second")
    }

    func testChangedSourceRefusesWholeBatch() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt"), b = try fixture.file("B.txt")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let plan = try BatchRenamer().preview(files: [a, b], options: options)
        try Data("changed".utf8).write(to: b)
        do { _ = try await BatchRenamer().apply(plan); XCTFail("Expected refusal") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testUndoRefusesChangedFile() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let service = BatchRenamer(), plan = try service.preview(files: [a], options: options)
        let receipt = try await service.apply(plan)
        try Data("changed".utf8).write(to: plan.entries[0].destination)
        do { _ = try await service.apply(receipt.undoPlan); XCTFail("Expected refusal") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testUndoNeverOverwritesNewOriginalName() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let service = BatchRenamer(), plan = try service.preview(files: [a], options: options)
        let receipt = try await service.apply(plan)
        try Data("new unrelated file".utf8).write(to: a)
        do { _ = try await service.apply(receipt.undoPlan); XCTFail("Expected conflict") } catch {}
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "new unrelated file")
    }

    func testCaseOnlyRenameAndUndo() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("Photo.txt")
        var options = BatchRenameOptions(); options.find = "Photo"; options.replacement = "photo"
        let service = BatchRenamer(), plan = try service.preview(files: [a], options: options)
        let receipt = try await service.apply(plan)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains("photo.txt"))
        _ = try await service.apply(receipt.undoPlan)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains("Photo.txt"))
    }

    func testCyclesUseStagingWithoutOverwriting() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt", contents: "first"), b = try fixture.file("B.txt", contents: "second")
        let plan = BatchRenamePlan(entries: [try entry(a, b), try entry(b, a)])
        let receipt = try await BatchRenamer().apply(plan)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "first")
        _ = try await BatchRenamer().apply(receipt.undoPlan)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
    }

    func testFailureDuringCommitRollsBackWholeCycle() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt", contents: "first"), b = try fixture.file("B.txt", contents: "second")
        let plan = BatchRenamePlan(entries: [try entry(a, b), try entry(b, a)])
        let counter = RenameFailureCounter(failAt: [4])
        let service = BatchRenamer(renameItem: { try counter.move($0, $1) })
        do { _ = try await service.apply(plan); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rolled back")) }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "second")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count, 2)
    }

    func testFailureDuringStagingRollsBackEarlierMove() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt"), b = try fixture.file("B.txt")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let counter = RenameFailureCounter(failAt: [2])
        let service = BatchRenamer(renameItem: { try counter.move($0, $1) })
        let plan = try service.preview(files: [a, b], options: options)
        do { _ = try await service.apply(plan); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testRollbackFailureReportsRecoveryLocation() async throws {
        let fixture = try RenameFixture(); defer { fixture.remove() }
        let a = try fixture.file("A.txt"), b = try fixture.file("B.txt")
        var options = BatchRenameOptions(); options.prefix = "New-"
        let counter = RenameFailureCounter(failAt: [2, 3])
        let service = BatchRenamer(renameItem: { try counter.move($0, $1) })
        let plan = try service.preview(files: [a, b], options: options)
        do { _ = try await service.apply(plan); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("need recovery")); XCTAssertTrue(error.localizedDescription.contains(".MacTools-Rename-")) }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains { $0.hasPrefix(".MacTools-Rename-") })
    }

    private func entry(_ source: URL, _ destination: URL) throws -> BatchRenameEntry {
        BatchRenameEntry(source: source, destination: destination, snapshot: try DuplicateFileAccess.validate(source), ancestors: try DuplicateFileAccess.ancestors(of: source))
    }
}

private struct RenameFixture {
    let root = URL(fileURLWithPath: "/private/tmp/MacTools-RenameTest-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func file(_ path: String, contents: String = "contents") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url); return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private final class RenameFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let failAt: Set<Int>
    init(failAt: Set<Int>) { self.failAt = failAt }
    func move(_ source: URL, _ destination: URL) throws {
        let count = lock.withLock { calls += 1; return calls }
        if failAt.contains(count) { throw FileSafetyError.refused("Injected rename failure.") }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw DuplicateFileAccess.posix(source) }
    }
}
