import Foundation
import XCTest
@testable import MacTools

@MainActor
final class KeyVaultModelTests: XCTestCase {
    func testLoadingIsLazyAndRepeatedAppearanceDoesNotReload() async throws {
        let saved = VaultEntry(content: .text("Saved note"))
        let store = FakeVaultStore(entries: [saved])
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: false, store: store, access: clipboard)
        defer { model.shutdown() }
        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(store.loadAttempts, 0)

        model.load()
        try await waitForIdle(model)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.entries, [saved])
        XCTAssertEqual(model.selectedEntry, saved)
        model.load()
        XCTAssertEqual(store.loadAttempts, 1)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
    }

    func testSaveLoadsExistingItemsAndDuplicateSelectsWithoutWritingAgain() async throws {
        let original = VaultEntry(content: .text("Existing entry"))
        let store = FakeVaultStore(entries: [original])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.query = "no match"
        model.save(.text("New entry"))
        try await waitForIdle(model)

        XCTAssertEqual(model.entries.map(\.content), [.text("New entry"), original.content])
        XCTAssertEqual(store.entries, model.entries)
        XCTAssertEqual(model.selectedEntry?.content, .text("New entry"))
        XCTAssertEqual(model.query, "")
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.error)

        model.save(original.content)
        try await waitForIdle(model)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertEqual(store.saveAttempts, 1)

        let reopened = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { reopened.shutdown() }
        reopened.load()
        try await waitForIdle(reopened)
        XCTAssertEqual(reopened.entries, model.entries)
    }

    func testFailedLoadCannotOverwriteExistingVaultAndSaveCanRetry() async throws {
        let original = VaultEntry(content: .text("Existing entry"))
        let store = FakeVaultStore(entries: [original])
        store.failLoad = true
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.save(.text("New entry"))
        try await waitForIdle(model)

        XCTAssertFalse(model.hasLoaded)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(store.saveAttempts, 0)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)

        store.failLoad = false
        model.save(.text("New entry"))
        try await waitForIdle(model)
        XCTAssertEqual(store.entries.map(\.content), [.text("New entry"), original.content])
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.error)
    }

    func testFailedSaveDoesNotPublishUnpersistedEntryOrSuccess() async throws {
        let original = VaultEntry(content: .text("Existing entry"))
        let store = FakeVaultStore(entries: [original])
        let gate = DispatchSemaphore(value: 0)
        store.saveGate = gate
        store.failSave = true
        defer { gate.signal() }
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.save(.text("Unsaved entry"))
        try await waitUntil { store.saveAttempts == 1 }

        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.entries, [original])
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertNil(model.notice)
        gate.signal()
        try await waitForIdle(model)

        XCTAssertEqual(model.entries, [original])
        XCTAssertEqual(store.entries, [original])
        XCTAssertEqual(model.selectedID, original.id)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)

        store.saveGate = nil
        store.failSave = false
        model.save(.text("Retry"))
        try await waitForIdle(model)
        XCTAssertEqual(store.entries.map(\.content), [.text("Retry"), original.content])
    }

    func testRemovalFailureKeepsEntryAndSuccessfulRetryRepairsSelection() async throws {
        let first = VaultEntry(content: .text("First"))
        let second = VaultEntry(content: .text("Second"))
        let store = FakeVaultStore(entries: [first, second])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        store.failSave = true
        model.remove(first)
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, [first, second])
        XCTAssertEqual(store.entries, [first, second])
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)

        store.failSave = false
        model.remove(first)
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, [second])
        XCTAssertEqual(store.entries, [second])
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertNil(model.error)
    }

    func testFailedReloadKeepsVisibleItemsButRequiresSuccessfulLoadBeforeSaving() async throws {
        let original = VaultEntry(content: .text("Existing entry"))
        let store = FakeVaultStore(entries: [original])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        store.failLoad = true
        model.load(force: true)
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, [original])
        XCTAssertFalse(model.hasLoaded)
        model.save(.text("Must not overwrite"))
        try await waitForIdle(model)
        XCTAssertEqual(store.saveAttempts, 0)
        XCTAssertEqual(store.entries, [original])
    }

    func testFinishPendingOperationWaitsForSaveIncludingInitialLoad() async throws {
        let store = FakeVaultStore()
        let gate = DispatchSemaphore(value: 0)
        store.loadGate = gate
        defer { gate.signal() }
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.save(.text("Finish before quitting"))
        try await waitUntil { store.loadAttempts == 1 }
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.isSaving)

        var finished = false
        let finish = Task { await model.finishPendingOperation(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertTrue(store.entries.isEmpty)
        gate.signal()
        await finish.value

        XCTAssertTrue(finished)
        XCTAssertEqual(store.entries.map(\.content), [.text("Finish before quitting")])
        XCTAssertFalse(model.isBusy)
    }

    func testShutdownDiscardsLateLoadPublicationWithoutDeletingSavedItems() async throws {
        let original = VaultEntry(content: .text("Saved entry"))
        let store = FakeVaultStore(entries: [original])
        let gate = DispatchSemaphore(value: 0)
        store.loadGate = gate
        defer { gate.signal() }
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        model.load()
        try await waitUntil { store.loadAttempts == 1 }
        model.shutdown()
        gate.signal()
        try await waitUntil { store.completedLoads == 1 }
        await Task.yield()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(store.entries, [original])
        model.save(.text("After shutdown"))
        XCTAssertEqual(store.saveAttempts, 0)
    }

    func testFullVaultRejectsNewItemWithoutEvictingSavedContent() async throws {
        let original = (0..<KeyVaultLimits.maximumCount).map { VaultEntry(content: .text("Saved \($0)")) }
        let store = FakeVaultStore(entries: original)
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.save(.text("Over the limit"))
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, original)
        XCTAssertEqual(store.entries, original)
        XCTAssertEqual(store.saveAttempts, 0)
        XCTAssertNotNil(model.error)
    }

    func testCopyIsExplicitAndFailureIsVisible() async throws {
        let entry = VaultEntry(content: .text("Copy me"))
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [entry]), access: clipboard)
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        model.copySelected()
        XCTAssertEqual(clipboard.writes, [entry.content])
        XCTAssertNotNil(model.notice)

        clipboard.writeSucceeds = false
        model.copySelected()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)
    }

    func testSensitiveMetadataPersistsAndSurvivesReopening() async throws {
        let store = FakeVaultStore()
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }

        model.save(.text("private recovery value"), title: "  Recovery code\n", isSensitive: true)
        try await waitForIdle(model)
        let saved = try XCTUnwrap(model.selectedEntry)
        XCTAssertEqual(saved.title, "Recovery code")
        XCTAssertTrue(saved.isSensitive)
        XCTAssertEqual(store.entries, [saved])

        model.updateMetadata(saved, title: "  Backup code  ", isSensitive: false)
        try await waitForIdle(model)
        let updated = try XCTUnwrap(model.selectedEntry)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.content, saved.content)
        XCTAssertEqual(updated.savedAt, saved.savedAt)
        XCTAssertEqual(updated.title, "Backup code")
        XCTAssertFalse(updated.isSensitive)

        let reopened = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { reopened.shutdown() }
        reopened.load()
        try await waitForIdle(reopened)
        XCTAssertEqual(reopened.entries, [updated])
    }

    func testFailedMetadataSaveKeepsPersistedProtectionAndPublishesNoCallback() async throws {
        let entry = VaultEntry(content: .text("private recovery value"), title: "Recovery code", isSensitive: true)
        let store = FakeVaultStore(entries: [entry])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)

        var callbacks: [[ClipboardContent]] = []
        model.onSensitiveContentsChange = { callbacks.append($0) }
        let gate = DispatchSemaphore(value: 0)
        store.saveGate = gate
        store.failSave = true
        defer { gate.signal() }

        model.updateMetadata(entry, title: "Changed name", isSensitive: false)
        try await waitUntil { store.saveAttempts == 1 }
        XCTAssertTrue(model.isSaving)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(store.entries, [entry])
        XCTAssertTrue(callbacks.isEmpty)

        gate.signal()
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(store.entries, [entry])
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)
    }

    func testDuplicateSaveNeverSilentlyRemovesSensitivity() async throws {
        let entry = VaultEntry(content: .text("private recovery value"), title: "Recovery code", isSensitive: true)
        let store = FakeVaultStore(entries: [entry])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }

        model.save(entry.content)
        try await waitForIdle(model)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertEqual(store.saveAttempts, 0)

        model.save(entry.content, title: "Renamed code", isSensitive: false)
        try await waitForIdle(model)
        let renamed = try XCTUnwrap(model.selectedEntry)
        XCTAssertEqual(renamed.id, entry.id)
        XCTAssertEqual(renamed.title, "Renamed code")
        XCTAssertTrue(renamed.isSensitive)
        XCTAssertEqual(store.entries, [renamed])
        XCTAssertEqual(store.saveAttempts, 1)
    }

    func testSavingDuplicateAsSensitiveUpgradesExistingItemWithoutAddingAnother() async throws {
        let entry = VaultEntry(content: .text("private recovery value"))
        let store = FakeVaultStore(entries: [entry])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }

        model.save(entry.content, title: "Recovery code", isSensitive: true)
        try await waitForIdle(model)
        let updated = try XCTUnwrap(model.selectedEntry)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(updated.id, entry.id)
        XCTAssertTrue(updated.isSensitive)
        XCTAssertEqual(updated.title, "Recovery code")
        XCTAssertEqual(store.entries, [updated])
    }

    func testSensitiveSearchMatchesNameWithoutDisclosingValueThroughResults() async throws {
        let secret = VaultEntry(content: .text("recovery-private-4298"), title: "Account recovery", isSensitive: true)
        let ordinary = VaultEntry(content: .text("Meeting notes"), title: "Project")
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [secret, ordinary]),
                                  access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)

        model.query = "private-4298"
        XCTAssertTrue(model.filteredEntries.isEmpty)
        model.query = "ACCOUNT"
        XCTAssertEqual(model.filteredEntries, [secret])
        model.query = "Meeting"
        XCTAssertEqual(model.filteredEntries, [ordinary])
        model.query = "Project"
        XCTAssertEqual(model.filteredEntries, [ordinary])
    }

    func testRevealIsExplicitAndChangingSelectionConcealsIt() async throws {
        let secret = VaultEntry(content: .text("private recovery value"), isSensitive: true)
        let ordinary = VaultEntry(content: .text("Meeting notes"))
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [secret, ordinary]),
                                  access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        XCTAssertNil(model.revealedID)

        model.revealSelected()
        XCTAssertEqual(model.revealedID, secret.id)
        model.selectedID = ordinary.id
        XCTAssertNil(model.revealedID)
        model.revealSelected()
        XCTAssertNil(model.revealedID)
        model.selectedID = secret.id
        XCTAssertNil(model.revealedID)
        model.revealSelected()
        model.conceal()
        XCTAssertNil(model.revealedID)
    }

    func testReloadImmediatelyConcealsEvenWhenTheReloadFails() async throws {
        let entry = VaultEntry(content: .text("private recovery value"), isSensitive: true)
        let store = FakeVaultStore(entries: [entry])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        model.revealSelected()
        XCTAssertEqual(model.revealedID, entry.id)

        store.failLoad = true
        model.load(force: true)
        XCTAssertNil(model.revealedID)
        try await waitForIdle(model)
        XCTAssertNil(model.revealedID)
        XCTAssertEqual(model.entries, [entry])
        XCTAssertNotNil(model.error)
    }

    func testSaveImmediatelyConcealsEvenWhenTheSaveFails() async throws {
        let entry = VaultEntry(content: .text("private recovery value"), isSensitive: true)
        let store = FakeVaultStore(entries: [entry])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        model.revealSelected()
        XCTAssertEqual(model.revealedID, entry.id)

        store.failSave = true
        model.save(.text("Another item"))
        XCTAssertNil(model.revealedID)
        try await waitForIdle(model)
        XCTAssertNil(model.revealedID)
        XCTAssertEqual(model.entries, [entry])
    }

    func testSensitiveCopyUsesConcealedWriteAndDoesNotFallBackOnFailure() async throws {
        let secret = VaultEntry(content: .text("private recovery value"), title: "Recovery code", isSensitive: true)
        let ordinary = VaultEntry(content: .text("Meeting notes"))
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [secret, ordinary]), access: clipboard)
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)

        XCTAssertTrue(model.copy(secret))
        XCTAssertEqual(clipboard.sensitiveWrites, [secret.content])
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(model.notice?.contains("30 seconds") == true)
        XCTAssertNil(model.revealedID)

        XCTAssertTrue(model.copy(ordinary))
        XCTAssertEqual(clipboard.writes, [ordinary.content])
        clipboard.writeSucceeds = false
        XCTAssertFalse(model.copy(secret))
        XCTAssertEqual(clipboard.sensitiveWrites, [secret.content, secret.content])
        XCTAssertEqual(clipboard.writes, [ordinary.content])
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.notice)
    }

    func testStaleOrdinaryEntryCannotBypassSensitiveCopyRouting() async throws {
        let ordinary = VaultEntry(content: .text("private recovery value"))
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [ordinary]), access: clipboard)
        defer { model.shutdown() }
        model.load()
        try await waitForIdle(model)
        model.updateMetadata(ordinary, title: "Recovery code", isSensitive: true)
        try await waitForIdle(model)

        XCTAssertFalse(model.copy(ordinary))
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(clipboard.sensitiveWrites.isEmpty)
        XCTAssertTrue(model.copy(try XCTUnwrap(model.selectedEntry)))
        XCTAssertEqual(clipboard.sensitiveWrites, [ordinary.content])
    }

    func testSensitiveContentsCallbackFollowsSuccessfulPersistence() async throws {
        let existing = VaultEntry(content: .text("Existing secret"), isSensitive: true)
        let ordinary = VaultEntry(content: .text("New secret"))
        let store = FakeVaultStore(entries: [existing, ordinary])
        let model = KeyVaultModel(isDemo: false, store: store, access: VaultClipboardAccess())
        defer { model.shutdown() }
        var callbacks: [[ClipboardContent]] = []
        model.onSensitiveContentsChange = { callbacks.append($0) }
        model.load()
        try await waitForIdle(model)
        XCTAssertEqual(callbacks, [[existing.content]])

        let gate = DispatchSemaphore(value: 0)
        store.saveGate = gate
        defer { gate.signal() }
        model.updateMetadata(ordinary, title: "New code", isSensitive: true)
        try await waitUntil { store.saveAttempts == 1 }
        XCTAssertEqual(callbacks, [[existing.content]])
        gate.signal()
        try await waitForIdle(model)
        XCTAssertEqual(callbacks, [[existing.content], [existing.content, ordinary.content]])

        store.saveGate = nil
        let updated = try XCTUnwrap(model.entries.first(where: { $0.id == ordinary.id }))
        model.remove(updated)
        try await waitForIdle(model)
        XCTAssertEqual(callbacks.last, [existing.content])
        XCTAssertEqual(callbacks.count, 3)
    }

    func testShutdownConcealsAndRequestsSensitiveClipboardCleanup() async throws {
        let entry = VaultEntry(content: .text("private recovery value"), isSensitive: true)
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: false, store: FakeVaultStore(entries: [entry]), access: clipboard)
        model.load()
        try await waitForIdle(model)
        model.revealSelected()
        XCTAssertTrue(model.copy(entry))

        model.shutdown()
        XCTAssertNil(model.revealedID)
        XCTAssertEqual(clipboard.sensitiveClearCount, 1)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.copy(entry))
    }

    func testDemoSensitiveChangesNeverTouchPersistenceOrHostClipboard() throws {
        let store = FakeVaultStore()
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: true, store: store, access: clipboard)
        let entry = try XCTUnwrap(model.entries.first(where: \.isSensitive))
        model.selectedID = entry.id
        model.revealSelected()
        XCTAssertEqual(model.revealedID, entry.id)
        XCTAssertFalse(model.copy(entry))
        model.updateMetadata(entry, title: "Changed demo name", isSensitive: false)
        XCTAssertFalse(try XCTUnwrap(model.selectedEntry).isSensitive)
        model.shutdown()

        XCTAssertEqual(store.loadAttempts, 0)
        XCTAssertEqual(store.saveAttempts, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(clipboard.sensitiveWrites.isEmpty)
        XCTAssertEqual(clipboard.sensitiveClearCount, 0)
    }

    func testDemoNeverTouchesPersistenceOrHostClipboard() throws {
        let store = FakeVaultStore()
        store.failLoad = true
        store.failSave = true
        let clipboard = VaultClipboardAccess()
        let model = KeyVaultModel(isDemo: true, store: store, access: clipboard)
        let originalCount = model.entries.count
        XCTAssertGreaterThan(originalCount, 0)
        model.load(force: true)
        model.save(.text("Demo saved item"))
        XCTAssertEqual(model.entries.count, originalCount + 1)
        XCTAssertEqual(model.selectedEntry?.content, .text("Demo saved item"))
        model.query = "DEMO"
        XCTAssertEqual(model.filteredEntries.count, 1)
        model.copySelected()
        model.remove(try XCTUnwrap(model.selectedEntry))
        XCTAssertEqual(model.entries.count, originalCount)
        model.shutdown()

        XCTAssertEqual(store.loadAttempts, 0)
        XCTAssertEqual(store.saveAttempts, 0)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertTrue(clipboard.writes.isEmpty)
        XCTAssertTrue(clipboard.sensitiveWrites.isEmpty)
        XCTAssertEqual(clipboard.sensitiveClearCount, 0)
    }

    private func waitForIdle(_ model: KeyVaultModel) async throws {
        try await waitUntil { !model.isBusy }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            guard Date() < deadline else { throw VaultTestError.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum VaultTestError: Error { case loadFailed, saveFailed, timeout }

private final class FakeVaultStore: KeyVaultPersistence, @unchecked Sendable {
    private struct State {
        var entries: [VaultEntry]
        var loadAttempts = 0
        var saveAttempts = 0
        var completedLoads = 0
        var failLoad = false
        var failSave = false
        var loadGate: DispatchSemaphore?
        var saveGate: DispatchSemaphore?
    }
    private let lock = NSLock()
    private var state: State
    init(entries: [VaultEntry] = []) { state = State(entries: entries) }

    var entries: [VaultEntry] { locked { $0.entries } }
    var loadAttempts: Int { locked { $0.loadAttempts } }
    var saveAttempts: Int { locked { $0.saveAttempts } }
    var completedLoads: Int { locked { $0.completedLoads } }
    var failLoad: Bool {
        get { locked { $0.failLoad } }
        set { locked { $0.failLoad = newValue } }
    }
    var failSave: Bool {
        get { locked { $0.failSave } }
        set { locked { $0.failSave = newValue } }
    }
    var loadGate: DispatchSemaphore? {
        get { locked { $0.loadGate } }
        set { locked { $0.loadGate = newValue } }
    }
    var saveGate: DispatchSemaphore? {
        get { locked { $0.saveGate } }
        set { locked { $0.saveGate = newValue } }
    }

    func load() throws -> [VaultEntry] {
        let (entries, failure, gate) = locked { state in
            state.loadAttempts += 1
            return (state.entries, state.failLoad, state.loadGate)
        }
        gate?.wait()
        locked { $0.completedLoads += 1 }
        if failure { throw VaultTestError.loadFailed }
        return entries
    }

    func save(_ entries: [VaultEntry]) throws {
        let (failure, gate) = locked { state in
            state.saveAttempts += 1
            return (state.failSave, state.saveGate)
        }
        gate?.wait()
        if failure { throw VaultTestError.saveFailed }
        locked { $0.entries = entries }
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

@MainActor
private final class VaultClipboardAccess: ClipboardAccess {
    var reads = 0
    var writes: [ClipboardContent] = []
    var sensitiveWrites: [ClipboardContent] = []
    var sensitiveClearCount = 0
    var writeSucceeds = true
    var changeCount: Int { reads += 1; return 0 }
    func candidate() -> ClipboardCandidate? { reads += 1; return nil }
    func write(_ content: ClipboardContent) -> Bool { writes.append(content); return writeSucceeds }
    func writeSensitive(_ content: ClipboardContent) -> Bool { sensitiveWrites.append(content); return writeSucceeds }
    func clearSensitive() { sensitiveClearCount += 1 }
}
