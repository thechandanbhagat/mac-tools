import AppKit
import Foundation

@MainActor
final class PortInspectorModel: ObservableObject {
    @Published private(set) var items: [ListeningPortItem] = []
    @Published var selectedID: String?
    @Published var query = ""
    @Published var transportFilter: NetworkTransportProtocol?
    @Published var onlyUserProcesses = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false
    @Published var pendingStopItem: ListeningPortItem?
    @Published var pendingForceStop = false
    @Published var banner: String?
    @Published var error: String?

    let isDemo: Bool
    private let service: PortInspector
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    init(
        isDemo: Bool = AppEnvironment.isDemo,
        service: PortInspector = PortInspector()
    ) {
        self.isDemo = isDemo
        self.service = service
    }

    var filteredItems: [ListeningPortItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if let transportFilter, item.transport != transportFilter { return false }
            if onlyUserProcesses && !item.isCurrentUser { return false }
            guard !trimmed.isEmpty else { return true }
            return String(item.port).contains(trimmed)
                || String(item.pid).contains(trimmed)
                || item.processName.localizedCaseInsensitiveContains(trimmed)
                || item.displayEndpoint.localizedCaseInsensitiveContains(trimmed)
                || (item.executablePath?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var selectedItem: ListeningPortItem? {
        if let selectedID, let match = filteredItems.first(where: { $0.id == selectedID }) {
            return match
        }
        return filteredItems.first
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isRefreshing else { return }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        generation += 1
        let activeGen = generation
        isRefreshing = true
        banner = nil
        error = nil

        if isDemo {
            let uid = getuid()
            items = [
                ListeningPortItem(pid: 4821, processName: "node", executablePath: "/opt/homebrew/bin/node", userID: uid, transport: .tcp, address: "127.0.0.1", port: 3000, ipVersion: "IPv4"),
                ListeningPortItem(pid: 5190, processName: "vite", executablePath: "/opt/homebrew/bin/node", userID: uid, transport: .tcp, address: "127.0.0.1", port: 5173, ipVersion: "IPv4"),
                ListeningPortItem(pid: 3104, processName: "postgres", executablePath: "/opt/homebrew/opt/postgresql@16/bin/postgres", userID: uid, transport: .tcp, address: "127.0.0.1", port: 5432, ipVersion: "IPv4"),
                ListeningPortItem(pid: 6012, processName: "python3", executablePath: "/usr/bin/python3", userID: uid, transport: .tcp, address: "0.0.0.0", port: 8000, ipVersion: "IPv4"),
                ListeningPortItem(pid: 412, processName: "ControlCenter", executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", userID: uid, transport: .tcp, address: "0.0.0.0", port: 7000, ipVersion: "IPv4")
            ]
            hasLoaded = true
            isRefreshing = false
            if selectedID == nil { selectedID = items.first?.id }
            return
        }

        let inspector = service
        refreshTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                try inspector.listListeningPorts()
            }.result

            guard activeGen == self.generation else { return }
            self.isRefreshing = false
            self.refreshTask = nil
            self.hasLoaded = true

            switch result {
            case .success(let ports):
                self.items = ports
                if let current = self.selectedID, ports.contains(where: { $0.id == current }) {
                    // Keep selection
                } else {
                    self.selectedID = ports.first?.id
                }
            case .failure(let err) where err is CancellationError:
                break
            case .failure(let err):
                self.error = err.localizedDescription
            }
        }
    }

    func requestStop(_ item: ListeningPortItem, force: Bool = false) {
        pendingStopItem = item
        pendingForceStop = force
    }

    func cancelStop() {
        pendingStopItem = nil
        pendingForceStop = false
    }

    func confirmStop() {
        guard let item = pendingStopItem else { return }
        let force = pendingForceStop
        pendingStopItem = nil
        pendingForceStop = false

        if isDemo {
            items.removeAll { $0.pid == item.pid }
            banner = "Demo mode: simulated stopping \(item.processName) (PID \(item.pid))."
            return
        }

        do {
            try service.terminate(item, force: force)
            banner = "\(force ? "Force quit" : "Sent quit signal to") \(item.processName) (PID \(item.pid) on port \(item.port))."
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                self.refresh()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func copyText(_ value: String, label: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(value, forType: .string) {
            banner = "Copied \(label)."
        }
    }

    func revealExecutable(_ item: ListeningPortItem) {
        guard let path = item.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func shutdown() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingStopItem = nil
    }
}
