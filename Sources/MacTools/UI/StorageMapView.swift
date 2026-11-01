import QuickLook
import SwiftUI

struct StorageMapView: View {
    @ObservedObject var model: StorageMapModel
    var onHandoffFolder: ((URL, AppTool) -> Void)? = nil
    var onHandoffFile: ((URL, AppTool) -> Void)? = nil
    @State private var quickLookURL: URL?

    private var issues: [ScanIssue] { model.result?.issues ?? [] }
    private var isPartial: Bool { model.currentNode?.isPartial == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let notice = model.notice {
                            Label(notice, systemImage: "info.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        scope.id("storage-map-location").disabled(model.isFileActionBusy)
                        if model.isScanning { scanningView }
                        if model.result != nil { resultsView(scroll: scroll) }
                    }
                    .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 28)
                }
                .onChange(of: model.navigationIDs) { previousIDs, _ in
                    if !previousIDs.isEmpty {
                        scroll.scrollTo("storage-map-location", anchor: .top)
                    }
                }
            }
            footer
        }
        .background(Palette.panel)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isScanning, !model.isDemo, let first = urls.first else { return false }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                model.setRoot(first)
                model.scan()
                return true
            }
            return false
        }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $model.showIssues) { issuesView }
        .sheet(item: Binding(get: { model.pendingTrash }, set: { if $0 == nil { model.cancelTrash() } })) { request in
            StorageMapTrashConfirmation(request: request, isDemo: model.isDemo,
                                        onCancel: model.cancelTrash, onConfirm: model.confirmTrash)
        }
        .alert(model.errorTitle, isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Storage Map").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HelpTip(
                text: "Opening a folder scans it automatically. Rescan or Command-R refreshes the current folder. Right-click a file or folder to move it to Trash after confirmation. Scans only read metadata and never download cloud contents.",
                label: "About storage map"
            )
        }
        .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)
    }

    @ViewBuilder
    private var scope: some View {
        if model.hasLocation {
            HStack(spacing: 12) {
                breadcrumbs
                Menu {
                    Toggle("Include hidden items", isOn: $model.includeHidden)
                        .help("Rescan the current folder with or without hidden items.")
                } label: {
                    Label("Scan options", systemImage: "slider.horizontal.3")
                }
                .labelStyle(.iconOnly)
                .fixedSize().menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Scan options").accessibilityLabel("Scan options")
                Button("Choose folder…") { model.chooseFolder() }.disabled(model.isScanning || model.isDemo)
            }
        } else {
            fullScope
        }
    }

    private var fullScope: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 13) {
                Image(systemName: "folder").font(.system(size: 25)).foregroundStyle(Palette.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isDemo ? "Sample files" : model.rootURL.lastPathComponent.isEmpty ? "Macintosh HD" : model.rootURL.lastPathComponent)
                        .font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if !model.isDemo {
                        Text(displayPath(model.rootURL))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(model.rootURL.path)
                    }
                }
                Spacer(minLength: 16)
                Button("Choose folder…") { model.chooseFolder() }.disabled(model.isScanning || model.isDemo)
            }
            HStack(spacing: 10) {
                quickScope("Home", symbol: "house", url: FileManager.default.homeDirectoryForCurrentUser)
                quickScope("Downloads", symbol: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                quickScope("Documents", symbol: "doc.text", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents"))
                quickScope("Desktop", symbol: "menubar.dock.rectangle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
                Spacer(minLength: 10)
                Toggle("Include hidden items", isOn: $model.includeHidden)
                    .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isScanning)
                    .help("Include items whose names begin with a dot or are marked hidden by macOS.")
            }
        }
        .padding(20)
        .background(Palette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private func quickScope(_ title: String, symbol: String, url: URL) -> some View {
        Button {
            model.setRoot(url)
            model.scan()
        } label: { Label(title, systemImage: symbol) }
            .controlSize(.small).disabled(model.isScanning || model.isDemo)
            .help("Scan \(title)")
    }

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scanning…")
                Spacer()
                Text("\(model.progressCount.formatted()) items checked").monospacedDigit()
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            ProgressView().progressViewStyle(.linear)
                .help(model.progressPath)
                .accessibilityLabel("Scanning \(model.currentURL.lastPathComponent)")
        }
        .accessibilityElement(children: .contain)
    }

    private func resultsView(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !issues.isEmpty { scanNotice }
            HStack(alignment: .firstTextBaseline) {
                Text(model.currentNode?.isPackage == true
                     ? "\(model.currentNode?.fileCount.formatted() ?? "0") files in package"
                     : "\(model.children.count.formatted()) items")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(bytes(model.currentTotal)).font(.system(size: 25, weight: .semibold)).monospacedDigit()
                        HelpTip(
                            text: "Rectangle area represents scanned size on disk. Each folder is scanned independently, so hard-link attribution can change when you enter a folder. Compression and shared storage can make totals differ from Finder. Partial sizes include only inspected files.",
                            label: "About storage sizes"
                        )
                    }
                    if isPartial {
                        Text("Partial scan").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let node = model.currentNode, node.isPackage {
                VStack(spacing: 4) {
                    ContentUnavailableView("Package contents grouped", systemImage: "shippingbox")
                    Button("Show package in Finder") { model.reveal(node) }
                }.frame(minHeight: 190)
            } else if model.children.isEmpty {
                ContentUnavailableView(
                    isPartial ? "Folder partially scanned" : "No items to show",
                    systemImage: isPartial ? "exclamationmark.circle" : "folder",
                    description: Text(isPartial
                        ? "See scan notices for details."
                        : "Try including hidden items or choose another folder.")
                ).frame(minHeight: 190)
            } else {
                if model.currentTotal > 0 {
                    StorageMapChart(nodes: model.children, onOpen: open,
                                    onShowAll: { scroll.scrollTo("storage-map-items", anchor: .top) },
                                    onReveal: model.reveal, onTrash: model.requestTrash, canTrash: model.canTrash)
                        .disabled(model.isFileActionBusy)
                } else {
                    Label((model.currentNode?.sharedFileCount ?? 0) > 0
                          ? "Hard-link sizes are counted elsewhere in this scan."
                          : "No scanned storage to map.", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
                itemList.id("storage-map-items")
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.breadcrumbs.count < 2)
                .help("Go to the parent folder and scan it").accessibilityLabel("Go to the parent folder")
                .keyboardShortcut("[", modifiers: .command)
            ScrollViewReader { pathScroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Group {
                                if node.id == model.navigationIDs.last {
                                    breadcrumbLabel(node, isRoot: index == 0)
                                        .font(.system(size: 13, weight: .semibold))
                                } else {
                                    Button {
                                        if index == 0 { model.goToRoot() }
                                        else { model.navigate(to: node) }
                                    } label: { breadcrumbLabel(node, isRoot: index == 0) }
                                    .buttonStyle(.link).font(.system(size: 12))
                                }
                            }
                            .help(node.url.path).id(node.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    if let lastID = model.navigationIDs.last { pathScroll.scrollTo(lastID, anchor: .trailing) }
                }
                .onChange(of: model.navigationIDs) { _, ids in
                    if let lastID = ids.last { pathScroll.scrollTo(lastID, anchor: .trailing) }
                }
            }
            if let node = model.breadcrumbs.last {
                Button { model.reveal(node) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Show current folder in Finder").accessibilityLabel("Show current folder in Finder")
            }
        }
    }

    @ViewBuilder
    private func breadcrumbLabel(_ node: StorageMapNode, isRoot: Bool) -> some View {
        if isRoot { Label(nodeTitle(node), systemImage: "folder") }
        else { Text(node.name) }
    }

    private var scanNotice: some View {
        HStack(spacing: 9) {
            Label("Some items weren’t scanned", systemImage: "exclamationmark.circle")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("\(issues.count.formatted()) \(issues.count == 1 ? "notice" : "notices")") { model.showIssues = true }
                .buttonStyle(.link).font(.system(size: 12))
        }.padding(13).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text("Size on disk")
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.frame(width: 94, alignment: .trailing).help("Sorted by size, largest first")
                Text("Of folder").frame(width: 72, alignment: .trailing)
                Color.clear.frame(width: 20, height: 1)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.bottom, 11)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(model.children) { node in
                    itemRow(node)
                    Divider().padding(.leading, 39)
                }
            }
        }
    }

    private func itemRow(_ node: StorageMapNode) -> some View {
        HStack(spacing: 12) {
            Button { open(node) } label: {
                HStack(spacing: 12) {
                    Image(systemName: node.isPackage ? "shippingbox" : node.isDirectory ? "folder" : "doc")
                        .font(.system(size: 20)).foregroundStyle(node.isDirectory ? Palette.accent : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        if let detail = itemDetail(node) {
                            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if node.isDirectory && !node.isPackage {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Text(bytes(node.byteCount)).font(.system(size: 12, weight: .medium))
                        .monospacedDigit().frame(width: 94, alignment: .trailing)
                    Text(percentage(node.byteCount)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(node.name), \(bytes(node.byteCount)), \(percentage(node.byteCount)) of folder\(itemDetail(node).map { ", " + $0 } ?? "")")
            .accessibilityHint(node.isDirectory && !node.isPackage ? "Opens and scans this folder" : "Shows this item in Finder")
            .help(node.isDirectory && !node.isPackage ? "Open and scan \(node.name)" : "Show \(node.name) in Finder")
            .accessibilityActions {
                if !node.isPackage && model.canTrash(node) {
                    Button("Move to Trash…") { model.requestTrash(node) }
                }
            }
            if !node.isDirectory {
                Button { quickLookURL = node.url } label: {
                    Image(systemName: "eye").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).frame(width: 20)
                .help("Quick Look").accessibilityLabel("Quick Look \(node.name)")
            }
            Button { model.reveal(node) } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).frame(width: 20)
            .help("Show in Finder").accessibilityLabel("Show \(node.name) in Finder")
        }
        .padding(.horizontal, 5).padding(.vertical, 13)
        .disabled(model.isFileActionBusy)
        .contextMenu {
            if node.isDirectory && !node.isPackage {
                Button("Open folder") { model.navigate(to: node) }
                if let onHandoffFolder {
                    Divider()
                    Button("Find Duplicates in Folder") { onHandoffFolder(node.url, .duplicates) }
                    Button("Scan in Large & Old Files") { onHandoffFolder(node.url, .largeFiles) }
                    Button("Scan in Developer Cleaner") { onHandoffFolder(node.url, .devCleaner) }
                    Button("Scan in Empty & Broken") { onHandoffFolder(node.url, .emptyItems) }
                    Divider()
                }
            } else if !node.isDirectory {
                Button("Quick Look") { quickLookURL = node.url }
                if let onHandoffFile {
                    Divider()
                    Button("Inspect Checksums") { onHandoffFile(node.url, .checksums) }
                    Button("Inspect Metadata") { onHandoffFile(node.url, .metadata) }
                    Button("Open in Batch Renamer") { onHandoffFile(node.url, .renamer) }
                    Divider()
                }
            }
            Button("Show in Finder") { model.reveal(node) }
            if !node.isPackage {
                Divider()
                Button("Move to Trash…", role: .destructive) { model.requestTrash(node) }
                    .disabled(!model.canTrash(node))
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                if let scannedAt = model.scannedAt {
                    Text("Scanned at \(scannedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .help("Last completed scan of \(model.currentURL.path)")
                }
                Spacer()
                if model.isFileActionBusy {
                    ProgressView().controlSize(.small)
                    Text(model.isTrashing ? "Moving to Trash…" : "Checking item…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.isPreparingTrash { Button("Cancel") { model.cancelTrash() } }
                } else if model.isScanning {
                    Button("Cancel scan") { model.cancel() }.controlSize(.large)
                } else {
                    Button { model.scan() } label: {
                        Label(model.result == nil ? "Scan folder" : "Rescan", systemImage: model.result == nil ? "magnifyingglass" : "arrow.clockwise")
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .help(model.isDemo && !model.hasLocation
                              ? "Scan sample files (Command-R)"
                              : "Scan \(model.currentURL.path) (Command-R)")
                }
            }.padding(.horizontal, 36).padding(.vertical, 20)
        }.background(Palette.panel)
    }

    private var issuesView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text("Scan notices").font(.system(size: 22, weight: .semibold))
                HelpTip(
                    text: "Partial folder sizes include only files this scan could inspect. Choose another folder or allow access when macOS asks, then scan again.",
                    label: "About partial scans"
                )
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(issue.message).font(.system(size: 12))
                            Text(issue.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 240)
            HStack {
                Spacer()
                Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560)
    }

    private func open(_ node: StorageMapNode) {
        if node.isDirectory && !node.isPackage { model.navigate(to: node) }
        else { model.reveal(node) }
    }

    private func itemDetail(_ node: StorageMapNode) -> String? {
        var details: [String] = []
        if node.sharedFileCount > 0 {
            if node.isDirectory {
                details.append("\(node.sharedFileCount.formatted()) shared \(node.sharedFileCount == 1 ? "entry" : "entries")")
            } else {
                details.append("Hard link · Size counted elsewhere")
            }
        }
        if node.isPartial { details.append("Partial scan") }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func nodeTitle(_ node: StorageMapNode) -> String {
        model.isDemo && node.url == model.rootURL ? "Sample files" : node.name
    }

    private func percentage(_ value: Int64) -> String {
        guard model.currentTotal > 0 else { return "—" }
        let percent = Double(value) / Double(model.currentTotal) * 100
        return percent > 0 && percent < 0.1 ? "<0.1%" : percent.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
