import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryModel
    @ObservedObject var vaultModel: KeyVaultModel
    @State private var itemToSave: ClipboardEntry?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Clipboard History").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                HelpTip(text: "Start remembers new text and image copies in session memory. Save to Key Vault keeps chosen items across launches. Up to \(model.history.maximumCount) history items and 20 MB are kept; change the history limit or enable capture on launch in Settings. Text over 256 KB and images over 8 MB or 16 megapixels are skipped. Images keep their pixel dimensions and are stored as PNG without metadata. Password-manager, concealed, and transient items are skipped when the source app marks them. Unmarked sensitive text can still be captured, so pause before copying it. Copy places the selected item on your clipboard; it never pastes into another app.", label: "About clipboard history")
            }
            .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)
            HStack(spacing: 24) {
                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search history", text: $model.query).textFieldStyle(.plain).accessibilityLabel("Search clipboard history")
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                        }
                    }.padding(10).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.entries) { item in
                                Button { model.selectedID = item.id; model.notice = nil } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: symbol(item.content)).foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(item.content.searchableText).font(.system(size: 13)).lineLimit(3).multilineTextAlignment(.leading)
                                            Text(item.capturedAt, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .background(model.selectedID == item.id ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                                    .accessibilityAddTraits(model.selectedID == item.id ? [.isSelected] : [])
                            }
                            if model.entries.isEmpty && !model.query.isEmpty {
                                Text("No matching items.").foregroundStyle(.secondary).font(.system(size: 13)).padding(.top, 24)
                            }
                        }
                    }
                }.frame(width: 280)
                Divider()
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 36).padding(.bottom, 24)
            Divider()
            HStack(spacing: 14) {
                Text(model.isMonitoring ? "Recording" : "Paused").font(.system(size: 12)).foregroundStyle(.secondary)
                if !model.history.entries.isEmpty {
                    Text("\(model.history.entries.count) \(model.history.entries.count == 1 ? "item" : "items")").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Clear") { model.clear() }.buttonStyle(.link)
                }
                Spacer()
                if let notice = vaultModel.notice ?? model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                Button("Save to Key Vault") {
                    itemToSave = model.selectedEntry
                }.disabled(model.selectedEntry == nil || vaultModel.isBusy).controlSize(.large)
                Button(model.isMonitoring ? "Pause" : "Start") { model.isMonitoring ? model.pause() : model.start() }
                    .disabled(model.isDemo).controlSize(.large)
                Button("Copy") { vaultModel.notice = nil; model.copySelected() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.selectedEntry == nil || model.isDemo)
            }.padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }.background(Palette.panel)
            .sheet(item: $itemToSave) { item in
                VaultItemDetailsView(heading: "Save to Key Vault", title: "", isSensitive: false, isBusy: vaultModel.isBusy) { title, sensitive in
                    guard !vaultModel.isBusy else { return }
                    model.notice = nil
                    vaultModel.save(item.content, title: title, isSensitive: sensitive)
                    itemToSave = nil
                } onCancel: { itemToSave = nil }
            }
            .onChange(of: model.selectedID) { _, _ in vaultModel.notice = nil }
            .alert(vaultModel.error == nil ? "Clipboard history" : "Key Vault", isPresented: Binding(
                get: { model.error != nil || vaultModel.error != nil },
                set: { if !$0 { model.error = nil; vaultModel.error = nil } }
            )) {
                Button("OK") { model.error = nil; vaultModel.error = nil }
            } message: { Text(vaultModel.error ?? model.error ?? "") }
    }

    @ViewBuilder private var preview: some View {
        if let item = model.selectedEntry {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(bytes(Int64(item.content.byteCount))).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.removeSelected() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Remove from history").accessibilityLabel("Remove selected item from history")
                }
                switch item.content {
                case .text(let text):
                    ScrollView { Text(text).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                case .image(let data, let width, let height):
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Clipboard image, \(width) by \(height) pixels")
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            ContentUnavailableView(model.isMonitoring ? "Copy something to begin" : "History is paused", systemImage: "clipboard",
                                   description: Text(model.isMonitoring ? "New text and images appear here." : "Start to remember new copies for this session."))
        }
    }
    private func symbol(_ content: ClipboardContent) -> String {
        switch content { case .text: "text.alignleft"; case .image: "photo" }
    }
}
