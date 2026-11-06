import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var quickPaste: VaultQuickPasteController
    @ObservedObject var launchAtLogin: LaunchAtLoginModel
    let isDemo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Settings").font(.system(size: 28, weight: .semibold))
                if isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                HelpTip(text: "Preferences are saved automatically on this Mac. Theme, the menu bar, and the history limit apply immediately. The opening page and clipboard capture preference apply on the next launch. Launch at login is managed by macOS. Tools run locally, without an account, uploads, or analytics.", label: "About settings")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)

            Form {
                Section("General") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }.pickerStyle(.segmented)

                    Picker("Open at launch", selection: $settings.startupTool) {
                        ForEach(AppSettings.startupTools) { tool in
                            Text(tool.title).tag(tool)
                        }
                    }
                    .help("The tool shown when Mac Tools launches.")

                    Toggle("Launch at login", isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                    .help(isDemo ? "Preview only. Demo mode does not change your login items." : "Start Mac Tools in the background at login with its menu bar icon. The main window stays closed.")
                    if let message = launchAtLogin.statusMessage {
                        HStack {
                            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Login Items Settings…") { launchAtLogin.openLoginItemsSettings() }
                                .disabled(isDemo)
                        }
                    }
                    if let error = launchAtLogin.errorMessage {
                        Text(error).font(.system(size: 12))
                    }
                }

                Section("Menu Bar") {
                    Toggle("Show Mac Tools in menu bar", isOn: $settings.showMenuBarItem)
                        .help("Quick access to your tools. Keeps Mac Tools running when its window is closed.")
                    Toggle("Show CPU usage", isOn: $settings.showMonitorMenuBar)
                        .disabled(!settings.showMenuBarItem)
                        .help("Replace the app icon with live CPU usage and include system readings in the menu.")
                }

                Section {
                    Toggle("Capture clipboard on launch", isOn: $settings.captureClipboardOnLaunch)
                        .help("On the next launch, capture new copies automatically. Start and Pause in Clipboard History control the current session.")
                    Picker("History limit", selection: $settings.clipboardHistoryLimit) {
                        ForEach(AppSettings.historyLimits, id: \.self) { limit in
                            Text("\(limit) items").tag(limit)
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Clipboard")
                        HelpTip(text: "History stays in memory, with a 20 MB total limit. Capture starts with your next copy; the existing clipboard is never imported. Marked sensitive items are skipped, but unmarked sensitive content can still be captured. Pause capture before copying it. Demo mode never reads or writes your clipboard.", label: "About clipboard capture")
                    }
                } footer: {
                    Text("Clipboard history clears when you quit. Lowering the limit removes older items.")
                }

                Section {
                    Toggle("Quick paste (⌃⌥V)", isOn: $settings.quickPasteEnabled)
                        .help("Open saved items from any app. Choose an item to paste into the original text field. Escape closes the picker.")
                    if settings.quickPasteEnabled && !isDemo && !quickPaste.isTrusted {
                        HStack {
                            Text("Allow Accessibility access to paste into other apps.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Accessibility Settings…") { quickPaste.openAccessibilitySettings() }
                        }
                    }
                    if let error = quickPaste.shortcutError {
                        Text(error).font(.system(size: 12))
                    }
                } header: {
                    Text("Key Vault")
                } footer: {
                    Text("Keeps Mac Tools running when its window is closed.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .padding(.horizontal, 16)

            Text("Mac Tools \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 36).padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel)
        .onAppear {
            quickPaste.refreshPermission()
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}
