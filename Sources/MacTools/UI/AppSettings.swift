import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Only preferences are persisted here; captured clipboard history remains session-local.
@MainActor
final class AppSettings: ObservableObject {
    enum Key {
        static let appearance = "appearance"
        static let startupTool = "startupTool"
        static let showMenuBarItem = "showMenuBarItem"
        static let showMonitorMenuBar = "showSystemMonitorMenuBar"
        static let captureClipboardOnLaunch = "captureClipboardOnLaunch"
        static let clipboardHistoryLimit = "clipboardHistoryLimit"
        static let quickPasteEnabled = "quickPasteEnabled"
    }

    static let historyLimits = [25, 50, 100, 200, 500]
    static var startupTools: [AppTool] { AppToolSection.allCases.flatMap(\.tools) }

    private let defaults: UserDefaults
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    @Published var startupTool: AppTool {
        didSet { defaults.set(startupTool.rawValue, forKey: Key.startupTool) }
    }
    @Published var showMonitorMenuBar: Bool {
        didSet { defaults.set(showMonitorMenuBar, forKey: Key.showMonitorMenuBar) }
    }
    @Published var showMenuBarItem: Bool {
        didSet { defaults.set(showMenuBarItem, forKey: Key.showMenuBarItem) }
    }
    @Published var captureClipboardOnLaunch: Bool {
        didSet { defaults.set(captureClipboardOnLaunch, forKey: Key.captureClipboardOnLaunch) }
    }
    @Published var clipboardHistoryLimit: Int {
        didSet { defaults.set(clipboardHistoryLimit, forKey: Key.clipboardHistoryLimit) }
    }
    @Published var quickPasteEnabled: Bool {
        didSet { defaults.set(quickPasteEnabled, forKey: Key.quickPasteEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        let savedTool = defaults.string(forKey: Key.startupTool).flatMap(AppTool.init(rawValue:))
        startupTool = savedTool.flatMap { Self.startupTools.contains($0) ? $0 : nil } ?? .cleaner
        let savedMonitorMenuBar = defaults.bool(forKey: Key.showMonitorMenuBar)
        showMonitorMenuBar = savedMonitorMenuBar
        // Preserve the existing monitor item on upgrade, then keep visibility independent.
        let savedMenuBarItem = defaults.object(forKey: Key.showMenuBarItem) as? Bool ?? savedMonitorMenuBar
        showMenuBarItem = savedMenuBarItem
        defaults.set(savedMenuBarItem, forKey: Key.showMenuBarItem)
        captureClipboardOnLaunch = defaults.bool(forKey: Key.captureClipboardOnLaunch)
        let savedLimit = defaults.integer(forKey: Key.clipboardHistoryLimit)
        clipboardHistoryLimit = Self.historyLimits.contains(savedLimit) ? savedLimit : 100
        quickPasteEnabled = defaults.object(forKey: Key.quickPasteEnabled) as? Bool ?? true
    }
}
