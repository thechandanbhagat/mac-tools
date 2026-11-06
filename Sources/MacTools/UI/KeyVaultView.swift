import SwiftUI

struct KeyVaultView: View {
    @ObservedObject var model: KeyVaultModel
    @State private var itemToDelete: VaultEntry?
    @State private var itemToEdit: VaultEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Key Vault").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                HelpTip(text: "Save a clipboard item from Clipboard History. Use Details to name it or mark it sensitive. Sensitive contents stay hidden until Reveal, hide again after 30 seconds or when you leave, and are searched only by name. Reveal does not require authentication. Copies are marked sensitive and clear after 30 seconds if the clipboard is unchanged; other apps may not respect the marker. Press Control–Option–V to choose an item for pasting. The vault is encrypted with a key in macOS Keychain. Clearing history does not remove saved items. Demo items are temporary.", label: "About Key Vault")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)

            if let error = model.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Text(error).font(.system(size: 13)).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { model.load(force: true) }.disabled(model.isBusy)
                }.padding(.horizontal, 36).padding(.bottom, 18)
            }

            HStack(spacing: 24) {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search saved items", text: $model.query)
                            .textFieldStyle(.plain).accessibilityLabel("Search Key Vault")
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                        }
                    }.padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))

                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.filteredEntries) { item in
                                Button { model.selectedID = item.id; model.notice = nil } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: item.isSensitive ? "lock" : symbol(item.content)).foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(item.listText).font(.system(size: 13)).lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                            Text(item.savedAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(model.selectedID == item.id ? Palette.accent.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedID == item.id ? [.isSelected] : [])
                            }
                            if model.filteredEntries.isEmpty && !model.query.isEmpty {
                                Text("No matching items.").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 24)
                            }
                        }
                    }
                }.frame(width: 280)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 36).padding(.bottom, 24)

            Divider()
            HStack(spacing: 14) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.entries.count) \(model.entries.count == 1 ? "item" : "items")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                Button("Details…") { model.conceal(); itemToEdit = model.selectedEntry }
                    .disabled(model.selectedEntry == nil || model.isBusy).controlSize(.large)
                Button("Delete…", role: .destructive) { model.conceal(); itemToDelete = model.selectedEntry }
                    .disabled(model.selectedEntry == nil || model.isBusy).controlSize(.large)
                Button("Copy") { model.copySelected() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.selectedEntry == nil || model.isBusy || model.isDemo)
            }.padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }
        .background(Palette.panel)
        .task { model.load() }
        .onDisappear { model.conceal() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.conceal() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in model.conceal() }
        .sheet(item: $itemToEdit) { item in
            VaultItemDetailsView(heading: "Item Details", title: item.title, isSensitive: item.isSensitive, isBusy: model.isBusy) { title, sensitive in
                guard !model.isBusy else { return }
                model.updateMetadata(item, title: title, isSensitive: sensitive)
                itemToEdit = nil
            } onCancel: { itemToEdit = nil }
        }
        .sheet(item: $itemToDelete) { item in
            VStack(alignment: .leading, spacing: 18) {
                Text("Delete saved item?").font(.system(size: 21, weight: .semibold))
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text("This permanently removes the item from Key Vault. Your current clipboard and clipboard history are unchanged.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { itemToDelete = nil }.keyboardShortcut(.defaultAction)
                    Button("Delete", role: .destructive) {
                        model.remove(item)
                        itemToDelete = nil
                    }.disabled(model.isBusy)
                }
            }.padding(26).frame(width: 470)
                .onExitCommand { itemToDelete = nil }
        }
    }

    @ViewBuilder private var preview: some View {
        if let item = model.selectedEntry {
            if item.isSensitive && model.revealedID != item.id {
                VStack(spacing: 14) {
                    Image(systemName: "eye.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Sensitive item").font(.system(size: 17, weight: .medium))
                    Button("Reveal") { model.revealSelected() }.disabled(model.isBusy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
              VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(bytes(Int64(item.content.byteCount))).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if item.isSensitive { Button("Hide") { model.conceal() } }
                }
                switch item.content {
                case .text(let text):
                    ScrollView {
                        Text(text).font(.system(size: 14)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .image(let data, let width, let height):
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .accessibilityLabel("Saved image, \(width) by \(height) pixels")
                    }
                }
                Spacer(minLength: 0)
              }
            }
        } else if model.isBusy {
            ProgressView("Opening Key Vault…")
        } else if model.error != nil {
            ContentUnavailableView("Key Vault unavailable", systemImage: "lock", description: Text("Retry to open your saved items."))
        } else {
            ContentUnavailableView("No saved items", systemImage: "lock.rectangle",
                                   description: Text("Save an item from Clipboard History to keep it here."))
        }
    }

    private func symbol(_ content: ClipboardContent) -> String {
        switch content { case .text: "text.alignleft"; case .image: "photo" }
    }
}

struct VaultItemDetailsView: View {
    let heading: String
    @State var title: String
    @State var isSensitive: Bool
    let isBusy: Bool
    let onSave: (String, Bool) -> Void
    let onCancel: () -> Void

    private var nameIsValid: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).count <= KeyVaultLimits.maximumTitleCharacters
            && title.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count <= KeyVaultLimits.maximumTitleBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(heading).font(.system(size: 21, weight: .semibold))
            LabeledContent("Name") {
                TextField("Name", text: $title, prompt: Text("Optional"))
                    .accessibilityLabel("Name")
                    .help("Names remain visible. Avoid putting a secret in the name.")
            }
            HStack {
                Toggle("Sensitive", isOn: $isSensitive)
                HelpTip(text: "Hides contents in lists, search, and previews until Reveal. Copies and pastes do not require authentication. Sensitive copies clear after 30 seconds if unchanged. The name remains visible.", label: "About sensitive items")
            }
            if isSensitive {
                Text("Matching items will be removed from Clipboard History.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !nameIsValid { Text("Use a name of up to 200 characters.").font(.system(size: 12)) }
            HStack {
                if isBusy { ProgressView().controlSize(.small).help("Key Vault is busy.") }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(title, isSensitive) }.keyboardShortcut(.defaultAction)
                    .disabled(!nameIsValid || isBusy)
            }
        }.padding(26).frame(width: 470)
    }
}
