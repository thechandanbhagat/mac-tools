import AppKit
import SwiftUI

@MainActor
final class StartupManagerModel: ObservableObject {
    typealias Inventory = @Sendable () async throws -> StartupInventory
    @Published private(set) var items: [StartupItem] = []
    @Published private(set) var issues: [StartupIssue] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasLoaded = false
    @Published var query = ""
    @Published var scope: StartupScope?
    @Published var error: String?
    @Published var showIssues = false
    let isDemo: Bool
    private let inventory: Inventory
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(isDemo: Bool = AppEnvironment.isDemo, inventory: Inventory? = nil) {
        self.isDemo = isDemo
        self.inventory = inventory ?? {
            if isDemo { return Self.demoInventory }
            return try await StartupManager().inventory()
        }
    }

    var filteredItems: [StartupItem] {
        items.filter {
            (scope == nil || $0.scope == scope) &&
            (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) ||
             ($0.program?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    func loadIfNeeded() { if !hasLoaded && !isBusy { refresh() } }

    func refresh() {
        task?.cancel()
        generation = UUID()
        let token = generation
        let inventory = inventory
        isBusy = true
        error = nil
        task = Task { [weak self] in
            do {
                let result = try await inventory()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.items = result.items
                self.issues = result.issues
                self.hasLoaded = true
                self.isBusy = false
                self.task = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                self.isBusy = false
                self.task = nil
            }
        }
    }

    func reveal(_ item: StartupItem) {
        guard !isDemo, items.contains(where: { $0.id == item.id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openLoginItems() {
        guard !isDemo else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            error = "Open System Settings → General → Login Items to manage sign-in and background items."
            return
        }
    }

    func shutdown() {
        generation = UUID()
        task?.cancel()
        task = nil
        isBusy = false
    }

    private nonisolated static var demoInventory: StartupInventory {
        StartupInventory(items: [
            StartupItem(url: URL(fileURLWithPath: "/Users/demo/Library/LaunchAgents/com.example.sync.plist"), label: "com.example.sync", program: "/Applications/Cloud Sync.app/Contents/MacOS/Cloud Sync", scope: .user, trigger: "At sign-in", disabledInFile: false),
            StartupItem(url: URL(fileURLWithPath: "/Library/LaunchAgents/com.example.updater.plist"), label: "com.example.updater", program: "/Library/Application Support/Example/Updater", scope: .allUsers, trigger: "Scheduled", disabledInFile: false),
            StartupItem(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.backup.plist"), label: "com.example.backup", program: "/Library/PrivilegedHelperTools/com.example.backup", scope: .system, trigger: "Keep alive", disabledInFile: false)
        ], issues: [])
    }
}
