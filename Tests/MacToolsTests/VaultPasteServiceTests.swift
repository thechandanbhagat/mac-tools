import XCTest
@testable import MacTools

@MainActor
final class VaultPasteServiceTests: XCTestCase {
    private let target = VaultPasteTarget(processIdentifier: 42, appName: "Editor")

    func testDemoNeverAccessesClipboardAccessibilityOrEventPosting() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: true, access: clipboard, environment: environment)
        XCTAssertFalse(service.isTrusted)
        XCTAssertNil(service.captureTarget())
        await expect(.demoDisabled) { try await service.paste(.text("Demo"), to: self.target) }
        await expect(.demoDisabled) { try await service.paste(.text("Demo secret"), to: self.target, isSensitive: true) }
        service.shutdown()
        XCTAssertEqual(environment.trustReads, 0)
        XCTAssertEqual(environment.captureCount, 0)
        XCTAssertEqual(environment.preparationCount, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(clipboard.sensitiveWrites.isEmpty)
        XCTAssertEqual(clipboard.sensitiveClearCount, 0)
        XCTAssertEqual(clipboard.readCount, 0)
    }

    func testCapturingDestinationDoesNotReadOrWriteClipboard() {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        let captured = service.captureTarget()
        XCTAssertEqual(captured?.processIdentifier, 42)
        XCTAssertEqual(captured?.appName, "Editor")
        XCTAssertEqual(environment.captureCount, 1)
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testMissingPermissionDoesNotActivateOrModifyClipboard() async {
        let environment = FakePasteEnvironment()
        environment.trusted = false
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        await expect(.accessibilityRequired) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertEqual(environment.activationCount, 0)
        XCTAssertEqual(environment.preparationCount, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    func testPasteWaitsForActivationAndReleasedKeysThenTargetsOriginalApp() async throws {
        let environment = FakePasteEnvironment()
        environment.frontmostProcessIdentifier = environment.ownProcessIdentifier
        environment.modifiersReleased = false
        let clipboard = RecordingPasteClipboard()
        var waits = 0
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: {
            waits += 1
            XCTAssertTrue(clipboard.writes.isEmpty)
            XCTAssertTrue(environment.postedTo.isEmpty)
            environment.frontmostProcessIdentifier = 42
            environment.modifiersReleased = true
        })
        let content = ClipboardContent.text("Saved notes — 東京\nSecond line")
        try await service.paste(content, to: target)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(environment.activationCount, 1)
        XCTAssertEqual(clipboard.writes, [content])
        XCTAssertEqual(environment.postedTo, [42])
        XCTAssertEqual(clipboard.readCount, 0)
    }

    func testSwitchingToAnotherAppAbortsWithoutStealingActivation() async {
        let environment = FakePasteEnvironment()
        environment.frontmostProcessIdentifier = 73
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        await expect(.targetChanged) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertEqual(environment.activationCount, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testChangedTextFieldCannotReceivePaste() async {
        let environment = FakePasteEnvironment()
        environment.focusIsOriginal = false
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: {})
        await expect(.targetChanged) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testAppSwitchDuringModifierWaitAborts() async {
        let environment = FakePasteEnvironment()
        environment.modifiersReleased = false
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: {
            environment.frontmostProcessIdentifier = 73
            environment.modifiersReleased = true
        })
        await expect(.targetChanged) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testTerminatedTargetCannotBeReusedWhileWaiting() async {
        let environment = FakePasteEnvironment()
        environment.modifiersReleased = false
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: {
            environment.targetRunning = false
            environment.modifiersReleased = true
        })
        await expect(.targetUnavailable) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testHeldModifiersTimeOutWithoutPasting() async {
        let environment = FakePasteEnvironment()
        environment.modifiersReleased = false
        let clipboard = RecordingPasteClipboard()
        var waits = 0
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: { waits += 1 })
        await expect(.modifiersHeld) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertEqual(waits, 30)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testClipboardFailureAndEventPreparationFailureNeverPost() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        clipboard.writeSucceeds = false
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        await expect(.clipboardWriteFailed) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertTrue(environment.postedTo.isEmpty)
        XCTAssertEqual(clipboard.writes.count, 1)

        environment.canPrepare = false
        await expect(.eventUnavailable) { try await service.paste(.text("Another"), to: self.target) }
        XCTAssertEqual(clipboard.writes.count, 1)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testPermissionAndFocusAreRecheckedAfterClipboardWrite() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        clipboard.onWrite = { environment.trusted = false }
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        await expect(.accessibilityRequired) { try await service.paste(.text("Saved"), to: self.target) }
        XCTAssertTrue(environment.postedTo.isEmpty)
        XCTAssertEqual(clipboard.writes, [.text("Saved")])

        environment.trusted = true
        clipboard.onWrite = { environment.focusIsOriginal = false }
        await expect(.targetChanged) { try await service.paste(.text("Another"), to: self.target) }
        XCTAssertTrue(environment.postedTo.isEmpty)
        XCTAssertEqual(clipboard.writes, [.text("Saved"), .text("Another")])
    }

    func testCancellationDuringWaitNeverWritesOrPosts() async {
        let environment = FakePasteEnvironment()
        environment.modifiersReleased = false
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment, wait: { throw CancellationError() })
        do {
            try await service.paste(.text("Saved"), to: target)
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testImagesUseNativeClipboardPayloadWithoutTextConversion() async throws {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        let image = ClipboardContent.image(Data([1, 2, 3]), width: 10, height: 10)
        try await service.paste(image, to: target)
        XCTAssertEqual(clipboard.writes, [image])
        XCTAssertEqual(environment.postedTo, [42])
    }

    func testSensitivePasteUsesConcealedClipboardWriteWithoutOrdinaryFallback() async throws {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        let secret = ClipboardContent.text("private recovery value")

        try await service.paste(secret, to: target, isSensitive: true)

        XCTAssertEqual(clipboard.sensitiveWrites, [secret])
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertEqual(environment.postedTo, [42])
        XCTAssertEqual(clipboard.sensitiveClearCount, 0)
    }

    func testSensitiveClipboardFailureNeverFallsBackOrPosts() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        clipboard.writeSucceeds = false
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)

        await expect(.clipboardWriteFailed) {
            try await service.paste(.text("private recovery value"), to: self.target, isSensitive: true)
        }

        XCTAssertEqual(clipboard.sensitiveWrites, [.text("private recovery value")])
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testFocusChangeAfterSensitiveWriteClearsOwnedClipboardAndDoesNotPost() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        clipboard.onSensitiveWrite = { environment.focusIsOriginal = false }
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)

        await expect(.targetChanged) {
            try await service.paste(.text("private recovery value"), to: self.target, isSensitive: true)
        }

        XCTAssertEqual(clipboard.sensitiveWrites, [.text("private recovery value")])
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(clipboard.sensitiveClearCount, 1)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testCancellationAfterSensitiveWriteClearsOwnedClipboardAndDoesNotPost() async {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        clipboard.onSensitiveWrite = { withUnsafeCurrentTask { $0?.cancel() } }
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        let destination = target
        let request = Task {
            try await service.paste(.text("private recovery value"), to: destination, isSensitive: true)
        }

        do {
            try await request.value
            XCTFail("A cancelled paste must not dispatch its prepared event.")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        XCTAssertEqual(clipboard.sensitiveWrites, [.text("private recovery value")])
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertEqual(clipboard.sensitiveClearCount, 1)
        XCTAssertTrue(environment.postedTo.isEmpty)
    }

    func testShutdownRequestsSensitiveClipboardCleanup() async throws {
        let environment = FakePasteEnvironment()
        let clipboard = RecordingPasteClipboard()
        let service = SystemVaultPasteService(isDemo: false, access: clipboard, environment: environment)
        try await service.paste(.text("private recovery value"), to: target, isSensitive: true)

        service.shutdown()

        XCTAssertEqual(clipboard.sensitiveClearCount, 1)
        XCTAssertEqual(environment.postedTo, [42])
    }

    private func expect(_ error: VaultPasteError, operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(error)", file: file, line: line)
        } catch let actual as VaultPasteError {
            XCTAssertEqual(actual, error, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class RecordingPasteClipboard: ClipboardAccess {
    var readCount = 0
    var writes: [ClipboardContent] = []
    var sensitiveWrites: [ClipboardContent] = []
    var sensitiveClearCount = 0
    var writeSucceeds = true
    var onWrite: (() -> Void)?
    var onSensitiveWrite: (() -> Void)?
    var changeCount: Int { readCount += 1; return 0 }
    func candidate() -> ClipboardCandidate? { readCount += 1; return nil }
    func write(_ content: ClipboardContent) -> Bool {
        writes.append(content)
        if writeSucceeds { onWrite?() }
        return writeSucceeds
    }
    func writeSensitive(_ content: ClipboardContent) -> Bool {
        sensitiveWrites.append(content)
        if writeSucceeds { onSensitiveWrite?() }
        return writeSucceeds
    }
    func clearSensitive() { sensitiveClearCount += 1 }
}

@MainActor
private final class FakePasteEnvironment: VaultPasteEnvironment {
    var trusted = true
    var trustReads = 0
    var isTrusted: Bool { trustReads += 1; return trusted }
    var ownProcessIdentifier: pid_t = 7
    var frontmostProcessIdentifier: pid_t? = 42
    var modifiersReleased = true
    var targetRunning = true
    var focusIsOriginal = true
    var canActivate = true
    var canPrepare = true
    var captureCount = 0
    var activationCount = 0
    var preparationCount = 0
    var postedTo: [pid_t] = []

    func captureTarget() -> VaultPasteTarget? {
        captureCount += 1
        return VaultPasteTarget(processIdentifier: 42, appName: "Editor")
    }
    func isTargetRunning(_ target: VaultPasteTarget) -> Bool { targetRunning }
    func activate(_ target: VaultPasteTarget) -> Bool { activationCount += 1; return canActivate }
    func focusMatches(_ target: VaultPasteTarget) -> Bool { focusIsOriginal }
    func preparePaste(to target: VaultPasteTarget) -> (@MainActor () -> Void)? {
        preparationCount += 1
        guard canPrepare else { return nil }
        return { self.postedTo.append(target.processIdentifier) }
    }
}
