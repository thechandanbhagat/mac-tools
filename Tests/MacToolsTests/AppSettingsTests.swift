import Foundation
import XCTest
@testable import MacTools

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFreshPreferencesUseDefaults() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.appearance, .system)
            XCTAssertEqual(settings.startupTool, .cleaner)
            XCTAssertFalse(settings.showMonitorMenuBar)
            XCTAssertFalse(settings.showMenuBarItem)
            XCTAssertFalse(settings.captureClipboardOnLaunch)
            XCTAssertEqual(settings.clipboardHistoryLimit, 100)
            XCTAssertTrue(settings.quickPasteEnabled)
        }
    }

    func testExistingAppearanceAndMenuBarPreferencesArePreserved() throws {
        try withDefaults { defaults in
            // These keys predate the dedicated Settings page.
            defaults.set("dark", forKey: "appearance")
            defaults.set(true, forKey: "showSystemMonitorMenuBar")

            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.appearance, .dark)
            XCTAssertTrue(settings.showMonitorMenuBar)
            XCTAssertTrue(settings.showMenuBarItem)
            XCTAssertEqual(settings.startupTool, .cleaner)
            XCTAssertFalse(settings.captureClipboardOnLaunch)
            XCTAssertEqual(settings.clipboardHistoryLimit, 100)
            XCTAssertTrue(settings.quickPasteEnabled)
        }
    }

    func testChangesPersistAcrossSettingsInstances() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.appearance = .light
            settings.startupTool = .clipboard
            settings.showMonitorMenuBar = true
            settings.showMenuBarItem = true
            settings.captureClipboardOnLaunch = true
            settings.clipboardHistoryLimit = 200
            settings.quickPasteEnabled = false

            let restored = AppSettings(defaults: defaults)
            XCTAssertEqual(restored.appearance, .light)
            XCTAssertEqual(restored.startupTool, .clipboard)
            XCTAssertTrue(restored.showMonitorMenuBar)
            XCTAssertTrue(restored.showMenuBarItem)
            XCTAssertTrue(restored.captureClipboardOnLaunch)
            XCTAssertEqual(restored.clipboardHistoryLimit, 200)
            XCTAssertFalse(restored.quickPasteEnabled)

            restored.appearance = .system
            restored.startupTool = .cleaner
            restored.showMonitorMenuBar = false
            restored.showMenuBarItem = false
            restored.captureClipboardOnLaunch = false
            restored.clipboardHistoryLimit = 100
            restored.quickPasteEnabled = true

            let reset = AppSettings(defaults: defaults)
            XCTAssertEqual(reset.appearance, .system)
            XCTAssertEqual(reset.startupTool, .cleaner)
            XCTAssertFalse(reset.showMonitorMenuBar)
            XCTAssertFalse(reset.showMenuBarItem)
            XCTAssertFalse(reset.captureClipboardOnLaunch)
            XCTAssertEqual(reset.clipboardHistoryLimit, 100)
            XCTAssertTrue(reset.quickPasteEnabled)
        }
    }

    func testDisabledQuickPastePreferenceIsNotReplacedByLaunchDefault() throws {
        try withDefaults { defaults in
            defaults.set(false, forKey: "quickPasteEnabled")

            let settings = AppSettings(defaults: defaults)
            XCTAssertFalse(settings.quickPasteEnabled)
            XCTAssertFalse(AppSettings(defaults: defaults).quickPasteEnabled)
        }
    }

    func testMenuBarVisibilityStaysOffAfterMigrationWhenCPUPreferenceIsOn() throws {
        try withDefaults { defaults in
            defaults.set(true, forKey: "showSystemMonitorMenuBar")
            let settings = AppSettings(defaults: defaults)
            XCTAssertTrue(settings.showMenuBarItem)
            settings.showMenuBarItem = false

            let restored = AppSettings(defaults: defaults)
            XCTAssertFalse(restored.showMenuBarItem)
            XCTAssertTrue(restored.showMonitorMenuBar)
        }
    }

    func testMenuBarIconCanBeEnabledWithoutCPUSampling() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.showMenuBarItem = true

            let restored = AppSettings(defaults: defaults)
            XCTAssertTrue(restored.showMenuBarItem)
            XCTAssertFalse(restored.showMonitorMenuBar)
        }
    }

    func testUnknownSavedAppearanceAndStartupToolFallBack() throws {
        try withDefaults { defaults in
            defaults.set("unsupported", forKey: "appearance")
            defaults.set("removed-tool", forKey: "startupTool")

            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.appearance, .system)
            XCTAssertEqual(settings.startupTool, .cleaner)
        }
    }

    func testUnsupportedSavedHistoryLimitsFallBack() throws {
        try withDefaults { defaults in
            for value in [-1, 0, 26, 1_000] {
                defaults.set(value, forKey: "clipboardHistoryLimit")
                XCTAssertEqual(AppSettings(defaults: defaults).clipboardHistoryLimit, 100,
                               "Unsupported saved limit: \(value)")
            }
        }
    }

    func testSettingsPageCannotBeTheStartupTool() throws {
        try withDefaults { defaults in
            defaults.set("settings", forKey: "startupTool")

            XCTAssertEqual(AppSettings(defaults: defaults).startupTool, .cleaner)
            XCTAssertFalse(AppSettings.startupTools.contains(.settings))
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "MacToolsTests.AppSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
