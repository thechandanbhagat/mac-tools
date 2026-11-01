import QuickLook
import SwiftUI

struct LargeFilesView: View {
    @ObservedObject var model: LargeFilesModel
    var onHandoffFile: ((URL, AppTool) -> Void)? = nil
    @State private var quickLookURL: URL?

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
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $model.showingReview) {
            LargeFilesReviewSheet(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Large & Old Files").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.allItems.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter files", text: $model.searchText)
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
                text: "Scans a chosen folder for large files (10 MB+) and lets you filter by minimum size, modification age, and file kind before moving selected items to Trash.",
                label: "About Large & Old Files"
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
                Text("Scanning for large files…").font(.system(size: 14, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report == nil {
            ContentUnavailableView {
                Label("Choose or drop a folder to scan", systemImage: "doc.zipper")
            } description: {
                Text("Find large archives, disk images, videos, and stale files across any folder.")
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
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if model.visibleItems.isEmpty {
                    ContentUnavailableView(
                        "No matching large files",
                        systemImage: "checkmark.circle",
                        description: Text("Try lowering the size or age filter.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visibleItems) { item in
                                fileRow(item)
                                Divider().padding(.leading, 32)
                            }
                        }
                        .padding(.horizontal, 36)
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Size", selection: $model.threshold) {
                ForEach(LargeFileThreshold.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Picker("Age", selection: $model.ageFilter) {
                ForEach(StaleFileAgeFilter.allCases) { age in
                    Text(age.rawValue).tag(age)
                }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("Kind", selection: $model.kindFilter) {
                Text("All kinds").tag(nil as LargeFileKind?)
                ForEach(LargeFileKind.allCases) { kind in
                    Text(kind.rawValue).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .frame(width: 170)

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

    private func fileRow(_ item: LargeFileItem) -> some View {
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
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(displayPath(item.url.deletingLastPathComponent().path)) · \(item.modifiedDate.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(bytes(item.byteCount))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                quickLookURL = item.url
            } label: {
                Image(systemName: "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Quick Look")
            .accessibilityLabel("Quick Look \(item.name)")

            Button {
                model.reveal(item)
            } label: {
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(item.name) in Finder")
        }
        .padding(.vertical, 11)
        .background(isSelected ? Palette.accent.opacity(0.045) : Color.clear)
        .contextMenu {
            Button("Quick Look") { quickLookURL = item.url }
            Button("Show in Finder") { model.reveal(item) }
            if let onHandoffFile {
                Divider()
                Button("Inspect Checksums") { onHandoffFile(item.url, .checksums) }
                Button("Inspect Metadata") { onHandoffFile(item.url, .metadata) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.selectedItems.isEmpty
                 ? "\(model.visibleItems.count) shown · \(bytes(model.visibleItems.reduce(0) { $0 + $1.byteCount }))"
                 : "\(model.selectedItems.count) selected · \(bytes(model.selectedBytes))")
                .font(.system(size: 12, weight: model.selectedItems.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.selectedItems.isEmpty ? .secondary : .primary)
                .monospacedDigit()
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

private struct LargeFilesReviewSheet: View {
    @ObservedObject var model: LargeFilesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move \(model.pendingReviewItems.count) \(model.pendingReviewItems.count == 1 ? "file" : "files") to Trash?")
                .font(.system(size: 20, weight: .semibold))
            Text("\(bytes(model.pendingReviewBytes)) on disk")
                .font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
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
                            Text(bytes(item.byteCount)).font(.system(size: 12)).monospacedDigit()
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
        .frame(width: 560)
        .background(Palette.panel)
    }
}
