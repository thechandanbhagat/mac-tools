import AppKit
import XCTest
@testable import MacTools

@MainActor
final class SensitiveClipboardTests: XCTestCase {
    func testSensitiveTextAndMarkerAreWrittenTogetherAndExcludedFromCapture() {
        withPasteboard { pasteboard in
            let access = SystemClipboardAccess(pasteboard: pasteboard)
            defer { access.clearSensitive() }

            XCTAssertTrue(access.writeSensitive(.text("private sample")))
            XCTAssertEqual(pasteboard.string(forType: .string), "private sample")
            XCTAssertTrue(pasteboard.types?.contains(SystemClipboardAccess.concealedType) == true)
            XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
            XCTAssertEqual(pasteboard.atomicWrites, 1)
            XCTAssertNil(access.candidate())
        }
    }

    func testSensitiveImageUsesOriginalPayloadAndConcealedMarker() {
        withPasteboard { pasteboard in
            let access = SystemClipboardAccess(pasteboard: pasteboard)
            defer { access.clearSensitive() }
            let payload = Data([1, 2, 3, 4])

            XCTAssertTrue(access.writeSensitive(.image(payload, width: 1, height: 1)))
            XCTAssertEqual(pasteboard.data(forType: .png), payload)
            XCTAssertTrue(pasteboard.types?.contains(SystemClipboardAccess.concealedType) == true)
            XCTAssertNil(access.candidate())
        }
    }

    func testExplicitClearRemovesOnlyOwnedSensitiveGeneration() {
        withPasteboard { pasteboard in
            let access = SystemClipboardAccess(pasteboard: pasteboard)
            XCTAssertTrue(access.writeSensitive(.text("private sample")))
            access.clearSensitive()
            XCTAssertNil(pasteboard.string(forType: .string))

            XCTAssertTrue(access.writeSensitive(.text("second private sample")))
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setString("new copy", forType: .string))
            access.clearSensitive()
            XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        }
    }

    func testPartiallyCommittedWriteFailureRemovesOwnedSecret() {
        withPasteboard { pasteboard in
            pasteboard.writeSucceeds = false
            let access = SystemClipboardAccess(pasteboard: pasteboard)

            XCTAssertFalse(access.writeSensitive(.text("private sample")))
            XCTAssertNil(pasteboard.string(forType: .string))
            XCTAssertNil(access.candidate()?.text)
        }
    }

    func testExpiryClearsSensitiveContentEvenAfterWriterIsReleased() async throws {
        let pasteboard = MemoryClipboardPasteboard()
        var access: SystemClipboardAccess? = SystemClipboardAccess(pasteboard: pasteboard,
                                                                  sensitiveLifetime: .milliseconds(20))
        weak var releasedAccess = access
        XCTAssertTrue(try XCTUnwrap(access).writeSensitive(.text("private sample")))
        access = nil
        XCTAssertNil(releasedAccess)

        try await waitUntil { pasteboard.string(forType: .string) == nil }
    }

    func testExpiryDoesNotEraseAnotherApplicationCopy() async throws {
        let pasteboard = MemoryClipboardPasteboard()
        let access = SystemClipboardAccess(pasteboard: pasteboard, sensitiveLifetime: .milliseconds(20))
        XCTAssertTrue(access.writeSensitive(.text("private sample")))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new copy", forType: .string))

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(pasteboard.string(forType: .string), "new copy")
        access.clearSensitive()
    }

    func testOrdinaryCopyReplacesSensitiveLeaseWithoutExpiringNewContent() async throws {
        let pasteboard = MemoryClipboardPasteboard()
        let access = SystemClipboardAccess(pasteboard: pasteboard, sensitiveLifetime: .milliseconds(20))
        XCTAssertTrue(access.writeSensitive(.text("private sample")))
        XCTAssertTrue(access.write(.text("ordinary copy")))

        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(pasteboard.string(forType: .string), "ordinary copy")
        XCTAssertFalse(pasteboard.types?.contains(SystemClipboardAccess.concealedType) == true)
        XCTAssertEqual(access.candidate()?.text, "ordinary copy")
        access.clearSensitive()
        XCTAssertEqual(pasteboard.string(forType: .string), "ordinary copy")
    }

    func testOlderWriterCannotClearNewSensitiveGeneration() {
        withPasteboard { pasteboard in
            let first = SystemClipboardAccess(pasteboard: pasteboard)
            let second = SystemClipboardAccess(pasteboard: pasteboard)
            defer { second.clearSensitive() }
            XCTAssertTrue(first.writeSensitive(.text("first private sample")))
            XCTAssertTrue(second.writeSensitive(.text("second private sample")))

            first.clearSensitive()
            XCTAssertEqual(pasteboard.string(forType: .string), "second private sample")
            second.clearSensitive()
            XCTAssertNil(pasteboard.string(forType: .string))
        }
    }

    func testUnimplementedSensitiveWriteFailsClosed() {
        let access = OrdinaryOnlyClipboard()
        XCTAssertFalse(access.writeSensitive(.text("private sample")))
        access.clearSensitive()
        XCTAssertTrue(access.writes.isEmpty)
    }

    private func withPasteboard(_ body: (MemoryClipboardPasteboard) throws -> Void) rethrows {
        let pasteboard = MemoryClipboardPasteboard()
        try body(pasteboard)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw SensitiveClipboardTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum SensitiveClipboardTestError: Error { case timeout }

/// Payload objects are local memory; this fake never creates an NSPasteboard.
@MainActor
private final class MemoryClipboardPasteboard: ClipboardPasteboard {
    private(set) var changeCount = 0
    private(set) var pasteboardItems: [NSPasteboardItem]?
    private(set) var atomicWrites = 0
    var writeSucceeds = true
    var types: [NSPasteboard.PasteboardType]? { pasteboardItems?.flatMap(\.types) }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        pasteboardItems?.first?.data(forType: type)
    }
    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        pasteboardItems?.first?.string(forType: type)
    }
    @discardableResult func clearContents() -> Int {
        changeCount += 1
        pasteboardItems = nil
        return changeCount
    }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        let item = pasteboardItems?.first ?? NSPasteboardItem()
        guard item.setString(string, forType: type) else { return false }
        pasteboardItems = [item]
        changeCount += 1
        return true
    }
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        let item = pasteboardItems?.first ?? NSPasteboardItem()
        guard let data, item.setData(data, forType: type) else { return false }
        pasteboardItems = [item]
        changeCount += 1
        return true
    }
    func writeItem(_ item: NSPasteboardItem) -> Bool {
        atomicWrites += 1
        pasteboardItems = [item]
        changeCount += 1
        return writeSucceeds
    }
}

@MainActor
private final class OrdinaryOnlyClipboard: ClipboardAccess {
    var writes: [ClipboardContent] = []
    var changeCount: Int { 0 }
    func candidate() -> ClipboardCandidate? { nil }
    func write(_ content: ClipboardContent) -> Bool { writes.append(content); return true }
}
