import Foundation
import SwiftUI

@MainActor
final class KeyVaultModel: ObservableObject {
    @Published private(set) var entries: [VaultEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasLoaded = false
    @Published var query = ""
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { conceal() } }
    }
    @Published private(set) var revealedID: UUID?
    @Published var error: String?
    @Published var notice: String?

    let isDemo: Bool
    var onSensitiveContentsChange: (([ClipboardContent]) -> Void)?
    private let store: (any KeyVaultPersistence)?
    private let access: (any ClipboardAccess)?
    private var task: Task<Void, Never>?
    private var concealTask: Task<Void, Never>?
    private var generation = UUID()
    private var isShutdown = false

    init(isDemo: Bool = AppEnvironment.isDemo, store: (any KeyVaultPersistence)? = nil,
         access: (any ClipboardAccess)? = nil) {
        self.isDemo = isDemo
        self.store = isDemo ? nil : (store ?? EncryptedKeyVaultStore())
        self.access = isDemo ? nil : (access ?? SystemClipboardAccess())
        if isDemo {
            entries = [
                VaultEntry(content: .text("Project notes\nReview the layout before the next release.")),
                VaultEntry(content: .text("https://developer.apple.com/documentation/")),
                VaultEntry(content: .text("DEMO-ONLY-7K9P-42"), title: "Example recovery code", isSensitive: true)
            ]
            selectedID = entries.first?.id
            hasLoaded = true
        }
    }

    var isBusy: Bool { isLoading || isSaving }
    var filteredEntries: [VaultEntry] {
        entries.filter { $0.matches(query) }
    }
    var selectedEntry: VaultEntry? { entries.first { $0.id == selectedID } }

    func load(force: Bool = false) {
        guard force || !hasLoaded else { return }
        perform(.load, forceReload: force)
    }

    func save(_ content: ClipboardContent, title: String = "", isSensitive: Bool = false) {
        perform(.save(content, title: title, isSensitive: isSensitive))
    }

    func updateMetadata(_ entry: VaultEntry, title: String, isSensitive: Bool) {
        perform(.metadata(entry.id, title: title, isSensitive: isSensitive))
    }

    func revealSelected() {
        guard !isBusy, let entry = selectedEntry, entry.isSensitive else { return }
        conceal()
        revealedID = entry.id
        concealTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.conceal()
        }
    }

    func conceal() {
        concealTask?.cancel()
        concealTask = nil
        revealedID = nil
    }

    /// The caller presents the removal confirmation before invoking this method.
    func remove(_ entry: VaultEntry) { perform(.remove(entry.id)) }

    func copySelected() {
        guard let entry = selectedEntry else { return }
        _ = copy(entry)
    }

    @discardableResult
    func copy(_ entry: VaultEntry) -> Bool {
        guard !isShutdown, !isDemo, !isBusy, entries.contains(entry), let access else { return false }
        error = nil
        notice = nil
        let written = entry.isSensitive ? access.writeSensitive(entry.content) : access.write(entry.content)
        if written { notice = entry.isSensitive ? "Copied. Clears in 30 seconds." : "Copied." }
        else { error = "Couldn’t copy this item. Try again." }
        return written
    }

    func finishPendingOperation() async { await task?.value }

    func shutdown() {
        isShutdown = true
        conceal()
        access?.clearSensitive()
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        isSaving = false
        entries = []
        selectedID = nil
        notice = nil
        // An already-issued atomic save may finish; shutdown never deletes the vault.
    }

    private enum Action {
        case load
        case save(ClipboardContent, title: String, isSensitive: Bool)
        case metadata(UUID, title: String, isSensitive: Bool)
        case remove(UUID)
    }

    private func perform(_ action: Action, forceReload: Bool = false) {
        guard !isShutdown, !isBusy else { return }
        conceal()
        error = nil
        notice = nil
        if isDemo {
            applyDemo(action)
            return
        }
        guard let store else { return }
        generation = UUID()
        let token = generation
        let needsLoad = forceReload || !hasLoaded
        if needsLoad { hasLoaded = false }
        isLoading = needsLoad
        // A requested save is pending even while its prerequisite load is running.
        if case .load = action {} else { isSaving = true }

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.isLoading = false
                    self.isSaving = false
                    self.task = nil
                }
            }
            if needsLoad {
                let result = await Task.detached(priority: .userInitiated) {
                    try store.load()
                }.result
                guard self.generation == token, !Task.isCancelled else { return }
                switch result {
                case .success(let loaded):
                    self.entries = loaded
                    self.publishSensitiveContents(loaded)
                    self.hasLoaded = true
                    if !loaded.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = loaded.first?.id
                    }
                    self.isLoading = false
                case .failure(let failure):
                    self.error = failure.localizedDescription
                    return
                }
            }
            guard self.generation == token, !Task.isCancelled else { return }
            do {
                guard let change = try self.proposedChange(for: action) else { return }
                self.isSaving = true
                let updated = change.entries
                let result = await Task.detached(priority: .userInitiated) {
                    try store.save(updated)
                }.result
                guard self.generation == token, !Task.isCancelled else { return }
                switch result {
                case .success:
                    self.commit(change)
                case .failure(let failure):
                    self.error = failure.localizedDescription
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private struct Change {
        let entries: [VaultEntry]
        let selectedID: UUID?
        let notice: String
        let clearsQuery: Bool
    }

    private func proposedChange(for action: Action) throws -> Change? {
        switch action {
        case .load:
            return nil
        case .save(let content, let title, let isSensitive):
            if let existing = entries.first(where: { $0.content == content }) {
                // Saving the same value again must never silently remove protection.
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if (isSensitive && !existing.isSensitive) || (!name.isEmpty && name != existing.title) {
                    return try proposedChange(for: .metadata(existing.id, title: name.isEmpty ? existing.title : name,
                                                              isSensitive: existing.isSensitive || isSensitive))
                }
                selectedID = existing.id
                query = ""
                notice = "Already saved in Key Vault."
                return nil
            }
            let entry = VaultEntry(content: content, title: title.trimmingCharacters(in: .whitespacesAndNewlines), isSensitive: isSensitive)
            let updated = [entry] + entries
            try KeyVaultLimits.validate(updated)
            return Change(entries: updated, selectedID: entry.id, notice: "Saved to Key Vault.", clearsQuery: true)
        case .metadata(let id, let title, let isSensitive):
            guard let existing = entries.first(where: { $0.id == id }) else { return nil }
            let entry = VaultEntry(id: id, content: existing.content, savedAt: existing.savedAt,
                                   title: title.trimmingCharacters(in: .whitespacesAndNewlines), isSensitive: isSensitive)
            let updated = entries.map { $0.id == id ? entry : $0 }
            try KeyVaultLimits.validate(updated)
            return Change(entries: updated, selectedID: id, notice: "Updated.", clearsQuery: true)
        case .remove(let id):
            guard entries.contains(where: { $0.id == id }) else { return nil }
            let updated = entries.filter { $0.id != id }
            let nextSelection = selectedID == id
                ? updated.first(where: { $0.matches(query) })?.id
                : selectedID
            return Change(entries: updated, selectedID: nextSelection, notice: "Removed from Key Vault.", clearsQuery: false)
        }
    }

    private func commit(_ change: Change) {
        conceal()
        publishSensitiveContents(change.entries)
        entries = change.entries
        selectedID = change.selectedID
        if change.clearsQuery { query = "" }
        notice = change.notice
    }

    private func publishSensitiveContents(_ entries: [VaultEntry]) {
        onSensitiveContentsChange?(entries.filter(\.isSensitive).map(\.content))
    }

    private func applyDemo(_ action: Action) {
        do {
            if let change = try proposedChange(for: action) { commit(change) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
