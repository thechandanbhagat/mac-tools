import QuickLook
import SwiftUI

struct CleanerView: View {
    @ObservedObject var model: CleanerModel
    var onHandoffFile: ((URL, AppTool) -> Void)? = nil
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if model.isDemo { demoNotice }
                    diskOverview
                    if let notice = model.notice { noticeView(notice) }
                    if model.phase == .ready { scopeView }
                    else if model.phase == .scanning { scanningView }
                    else { resultsView }
                }
                .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 24)
            }
            footer
        }
        .background(Palette.panel)
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $model.showReview) { ReviewView(model: model) }
        .sheet(isPresented: $model.showIssues) { issuesView }
        .alert("Something needs your attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Cleaner").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HelpTip(text: "Scan selected locations, then choose files to review. System files, apps, and package contents are excluded. Nothing is selected automatically. Cleaning moves files to Trash; space is freed after you empty Trash yourself.", label: "How cleaning works")
        }
        .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 28)
    }

    private var diskOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(model.disk?.name ?? "Your Mac", systemImage: "internaldrive")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if let disk = model.disk {
                    Text("\(bytes(disk.available)) available").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
            }
            if let disk = model.disk {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5).fill(Palette.accent.opacity(0.10))
                        RoundedRectangle(cornerRadius: 5).fill(Palette.accent).frame(width: max(0, geometry.size.width * disk.fraction))
                    }
                }.frame(height: 13)
                    .accessibilityLabel("Storage usage")
                    .accessibilityValue("\(bytes(disk.used)) used of \(bytes(disk.total))")
                HStack {
                    Text("\(bytes(disk.used)) used")
                    Spacer()
                    Text("\(bytes(disk.total)) total")
                }.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text("Storage information is unavailable. You can still scan your files.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .background(Palette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scopeView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan locations").font(.system(size: 18, weight: .semibold)).padding(.bottom, 12)
            ForEach(CleanupCategory.allCases) { category in
                scopeRow(category)
                if category != CleanupCategory.allCases.last { Divider().padding(.leading, 43) }
            }
        }
    }

    private func scopeRow(_ category: CleanupCategory) -> some View {
        HStack(spacing: 15) {
            Image(systemName: category.symbol).font(.system(size: 22, weight: .regular))
                .foregroundStyle(Palette.accent).frame(width: 28)
            Text(category.title).font(.system(size: 14, weight: .medium))
            HelpTip(text: "\(category.explanation)\n\(category.location)", label: "About \(category.title)")
            Spacer(minLength: 8)
            Toggle(category.title, isOn: Binding(get: { model.enabledCategories.contains(category) }, set: {
                if $0 { model.enabledCategories.insert(category) } else { model.enabledCategories.remove(category) }
            })).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Scan \(category.title)")
        }.padding(.vertical, 15)
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Scanning…").font(.system(size: 20, weight: .semibold))
                Spacer()
                ProgressView().controlSize(.small)
            }
            ProgressView().progressViewStyle(.linear)
            Text("\(model.progressCount.formatted()) items checked")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Text(model.progressPath).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }.padding(.top, 4)
        .accessibilityElement(children: .contain)
    }

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.items.isEmpty ? "Scan results" : "Files to review")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(model.items.count.formatted()) \(model.items.count == 1 ? "file" : "files") · \(bytes(model.totalBytes)) to review")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan again") { model.startScan() }.disabled(model.isBusy)
            }
            if !model.issues.isEmpty {
                Button { model.showIssues = true } label: {
                    Label("\(model.issues.count) scan \(model.issues.count == 1 ? "notice" : "notices") · View details", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12))
                }.buttonStyle(.link)
            }
            if model.items.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: model.issues.isEmpty ? "folder" : "exclamationmark.circle", description: Text(model.issues.isEmpty ? "No eligible files were found. Try different scan locations." : "Some locations couldn’t be fully scanned. Check the scan notices above, then try again."))
                    .frame(minHeight: 180)
            } else {
                categoryFilters
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter by name or path", text: $model.query).textFieldStyle(.plain)
                        if !model.query.isEmpty {
                            Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Clear filter")
                        }
                    }.padding(9).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                    Picker("Sort", selection: $model.sortLargestFirst) {
                        Text("Largest first").tag(true)
                        Text("Name A–Z").tag(false)
                    }.labelsHidden().frame(width: 136)
                }
                fileList
            }
        }
    }

    private var categoryFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterButton(title: "All files", category: nil, count: model.items.count, totalBytes: model.totalBytes)
                ForEach(CleanupCategory.allCases) { category in
                    if model.count(for: category) > 0 {
                        filterButton(title: category.title, category: category, count: model.count(for: category), totalBytes: model.size(for: category))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func filterButton(title: String, category: CleanupCategory?, count: Int, totalBytes: Int64) -> some View {
        Button { model.filter = category } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count.formatted()) · \(bytes(totalBytes))").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 11, weight: model.filter == category ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(model.filter == category ? Palette.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(model.filter == category ? Palette.accent : .primary)
        }.buttonStyle(.plain).accessibilityAddTraits(model.filter == category ? [.isSelected] : [])
    }

    private var fileList: some View {
        let visible = model.filteredItems
        return VStack(spacing: 0) {
            HStack {
                Text("\(visible.count.formatted()) \(visible.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                Spacer()
                Button("Select all \(visible.count.formatted())") { model.selectFiltered() }.buttonStyle(.link).disabled(visible.isEmpty || model.isBusy)
                Text("·").foregroundStyle(.secondary)
                Button("Clear selection") { model.selectedIDs = [] }.buttonStyle(.link).disabled(model.selectedIDs.isEmpty || model.isBusy)
            }.font(.system(size: 11)).padding(.bottom, 10)
            Divider()
            if visible.isEmpty {
                ContentUnavailableView.search(text: model.query).frame(height: 170)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { item in
                        fileRow(item)
                        Divider().padding(.leading, 37)
                    }
                }
            }
        }
    }

    private func fileRow(_ item: StorageItem) -> some View {
        HStack(spacing: 12) {
            Toggle("Select \(item.name)", isOn: Binding(get: { model.selectedIDs.contains(item.id) }, set: { _ in model.toggle(item) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(model.isBusy)
            Button { model.toggle(item) } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.category.symbol).font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(displayPath(item.url.deletingLastPathComponent().path))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(bytes(item.byteCount)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 80, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            Button { quickLookURL = item.url } label: { Image(systemName: "eye").font(.system(size: 13)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Quick Look").accessibilityLabel("Quick Look \(item.name)")
            Button { model.reveal(item) } label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 14)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Show in Finder").accessibilityLabel("Show \(item.name) in Finder")
        }
        .padding(.vertical, 13).padding(.horizontal, 5)
        .background(model.selectedIDs.contains(item.id) ? Palette.accent.opacity(0.045) : .clear)
        .contextMenu {
            Button("Quick Look") { quickLookURL = item.url }
            Button("Show in Finder") { model.reveal(item) }
            if let onHandoffFile {
                Divider()
                Button("Inspect Checksums") { onHandoffFile(item.url, .checksums) }
                Button("Inspect Metadata") { onHandoffFile(item.url, .metadata) }
                Button("Open in Batch Renamer") { onHandoffFile(item.url, .renamer) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if model.phase == .results || model.phase == .cleaning {
                        Text("\(model.selectedItems.count.formatted()) selected · \(bytes(model.selectedBytes))")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    }
                }
                Spacer()
                if model.phase == .scanning {
                    Button("Cancel scan") { model.cancelScan() }.controlSize(.large)
                } else if model.phase == .cleaning {
                    ProgressView().controlSize(.small)
                    Text("Moving to Trash…").font(.system(size: 13))
                } else if model.phase == .results {
                    Button("Scan locations") { model.reset() }.buttonStyle(.bordered)
                    Button { model.showReview = true } label: { Label("Review selection", systemImage: "arrow.right") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.selectedIDs.isEmpty)
                } else {
                    Button { model.startScan() } label: { Label("Scan storage", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.enabledCategories.isEmpty)
                }
            }.padding(.horizontal, 36).padding(.vertical, 20)
        }.background(Palette.panel)
    }

    private var demoNotice: some View {
        Label("Demo mode · Sample files only. Cleaning is disabled.", systemImage: "eye")
            .font(.system(size: 12)).foregroundStyle(.secondary)
    }
    private func noticeView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).accessibilityLabel("Dismiss notice")
        }.padding(14).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
    private var issuesView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Scan notices").font(.system(size: 22, weight: .semibold))
            Text("Some files may be inaccessible, excluded, or outside the scan limits. Results only include files the app could inspect.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.system(size: 12)).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 240)
            HStack {
                Text("Allow folder access in System Settings if macOS requests it.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560)
    }
}
