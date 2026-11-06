import SwiftUI

struct VaultQuickPasteView: View {
    @ObservedObject var controller: VaultQuickPasteController
    @ObservedObject var vault: KeyVaultModel
    @ObservedObject var settings: AppSettings
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Key Vault").font(.system(size: 15, weight: .semibold))
                if vault.isDemo { Text("Demo").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Text("⌃⌥V").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextField("Search saved items", text: $controller.query)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .accessibilityLabel("Search Key Vault")
                .onChange(of: controller.query) { _, _ in
                    controller.selectedID = nil
                    controller.resizePanel()
                }

            if vault.isLoading {
                ProgressView("Opening Key Vault…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vault.error {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.system(size: 12))
                    Button("Retry") { vault.load(force: true) }.disabled(vault.isBusy)
                }.frame(maxHeight: .infinity, alignment: .top)
            } else if controller.filteredEntries.isEmpty {
                ContentUnavailableView(controller.query.isEmpty ? "No saved items" : "No matches", systemImage: "lock.rectangle",
                                       description: Text(controller.query.isEmpty ? "Save items from Clipboard History." : "Try another search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(controller.filteredEntries) { entry in
                                Button { controller.choose(entry) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: entry.isSensitive ? "lock" : symbol(entry.content)).frame(width: 16).foregroundStyle(.secondary)
                                        Text(entry.listText).font(.system(size: 13)).lineLimit(2)
                                            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(9).contentShape(Rectangle())
                                    .background(controller.selectedID == entry.id ? Palette.accent.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).id(entry.id)
                                    .disabled(vault.isBusy || controller.isPasting)
                                    .accessibilityLabel("Paste \(entry.displayTitle)")
                                    .accessibilityAddTraits(controller.selectedID == entry.id ? [.isSelected] : [])
                            }
                        }
                    }
                    .onChange(of: controller.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }

            if let error = controller.error {
                Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            } else if !controller.isTrusted && !vault.isDemo {
                Text("Allow Accessibility access to paste into other apps.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 10) {
                if let notice = controller.notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let target = controller.targetName {
                    Text("Paste into \(target)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !controller.isTrusted && !vault.isDemo {
                    Button("Accessibility Settings…") { controller.openAccessibilitySettings() }.controlSize(.small)
                }
                Button("Copy") { controller.copySelected() }.controlSize(.small)
                    .disabled(controller.filteredEntries.isEmpty || vault.isBusy || vault.isDemo || controller.isPasting)
            }
        }
        .padding(16).frame(width: 380, height: controller.panelHeight)
        .background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 12)).tint(Palette.accent)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear { searchFocused = true }
        .onChange(of: vault.isLoading) { _, _ in controller.resizePanel() }
        .onChange(of: vault.entries.count) { _, _ in controller.resizePanel() }
        .onChange(of: controller.error) { _, _ in controller.resizePanel() }
    }

    private func symbol(_ content: ClipboardContent) -> String {
        switch content { case .text: "text.alignleft"; case .image: "photo" }
    }
}
