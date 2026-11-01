import SwiftUI

struct EmptyItemsView: View {
    @ObservedObject var model: EmptyItemsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopeBar
            Divider()
            if let banner = model.banner {
                bannerBar(banner)
                Divider()
            }
            content
            Divider()
            footer
        }
        .background(Palette.panel)
        .onAppear { model.prepareDemoIfNeeded() }
        .dropDestination(for: URL.self) { urls, _ in
            if let first = urls.first {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                    model.scan(folder: first)
                    return true
                }
            }
            return false
        }
        .sheet(isPresented: $model.showingReview) {
            EmptyItemsReviewSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Empty & Broken").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.allItems.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter items", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(width: 210)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
            }
            HelpTip(
                text: "Scans a chosen folder for empty directories and broken symbolic links whose targets no longer exist. Revalidates that directories are still empty before moving selections to Trash.",
                label: "About Empty & Broken"
            )
        }
        .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 22)
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(model.quickFolders, id: \.url) { item in
                let isCurrent = model.rootURL?.standardized.path == item.url.standardized.path
                Button(item.title) {
                    model.scan(folder: item.url)
                }
                .buttonStyle(.bordered)
                .tint(isCurrent ? Palette.accent : nil)
                .controlSize(.small)
                .disabled(model.isScanning || model.isCleaning)
            }
            Button("Choose folder…") {
                model.chooseFolder()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isScanning || model.isCleaning)

            if let rootURL = model.rootURL {
                Text(displayPath(rootURL.path))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.rootURL != nil {
                Button("Rescan") { model.scan() }
                    .controlSize(.small)
                    .disabled(model.isScanning || model.isCleaning)
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 12)
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { model.banner = nil }
                .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Scanning for empty folders and broken links…")
                    .font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report == nil {
            ContentUnavailableView {
                Label("Choose or drop a folder to scan", systemImage: "folder.badge.minus")
            } description: {
                Text("Find empty directories and broken symbolic links inside a folder tree.")
            } actions: {
                HStack(spacing: 8) {
                    ForEach(model.quickFolders.prefix(3), id: \.url) { item in
                        Button("Scan \(item.title)") { model.scan(folder: item.url) }
                            .buttonStyle(.bordered)
                    }
                    Button("Choose folder…") { model.chooseFolder() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.allItems.isEmpty {
            ContentUnavailableView(
                "No empty folders or broken links found",
                systemImage: "checkmark.circle",
                description: Text(model.rootURL.map { displayPath($0.path) } ?? "")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleItems) { item in
                            itemRow(item)
                            Divider().padding(.leading, 32)
                        }
                    }
                    .padding(.horizontal, 36)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Kind", selection: $model.kindFilter) {
                Text("All (\(model.allItems.count))").tag(nil as EmptyItemKind?)
                ForEach(EmptyItemKind.allCases) { kind in
                    let count = model.allItems.filter { $0.kind == kind }.count
                    Text("\(kind.rawValue) (\(count))").tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            Button("Select all \(model.visibleItems.count)") {
                model.selectAllVisible()
            }
            .buttonStyle(.link).font(.system(size: 11))
            .disabled(model.visibleItems.isEmpty)

            if !model.selectedIDs.isEmpty {
                Text("·").foregroundStyle(.secondary).font(.system(size: 11))
                Button("Clear") {
                    model.clearSelection()
                }
                .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
    }

    private func itemRow(_ item: EmptyCleanupItem) -> some View {
        let isSelected = model.selectedIDs.contains(item.id)
        return HStack(spacing: 12) {
            Toggle(
                "Select \(item.name)",
                isOn: Binding(get: { isSelected }, set: { _ in model.toggleSelection(item.id) })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            Button {
                model.toggleSelection(item.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(item.kind == .brokenSymlink ? .orange : Palette.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(item.kind.rawValue)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if let dest = item.linkDestination {
                            Text("\(displayPath(item.url.path)) → \(dest) (missing)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(displayPath(item.url.path))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.reveal(item)
            } label: {
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show Parent Folder in Finder")
        }
        .padding(.vertical, 11)
        .background(isSelected ? Palette.accent.opacity(0.045) : Color.clear)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.selectedItems.isEmpty
                 ? "\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "item" : "items")"
                 : "\(model.selectedItems.count) selected")
                .font(.system(size: 12, weight: model.selectedItems.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.selectedItems.isEmpty ? .secondary : .primary)
            Spacer()
            if model.isScanning {
                Button("Cancel") { model.cancelScan() }.controlSize(.large)
            } else if model.report == nil {
                Button("Choose folder…") { model.chooseFolder() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button("Review…") { model.presentReview() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.selectedItems.isEmpty || model.isCleaning)
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 18)
    }
}

private struct EmptyItemsReviewSheet: View {
    @ObservedObject var model: EmptyItemsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move \(model.pendingReviewItems.count) \(model.pendingReviewItems.count == 1 ? "item" : "items") to Trash?")
                .font(.system(size: 20, weight: .semibold))
            Text("Empty directories are checked again before moving to ensure no files were added.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.pendingReviewItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 13, weight: .medium))
                                Text(displayPath(item.url.path))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(item.kind.rawValue).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 220)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { model.cancelReview() }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.confirmTrash() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Palette.panel)
    }
}
