import SwiftUI

struct DeveloperCleanerView: View {
    @ObservedObject var model: DeveloperCleanerModel
    var onHandoffFolder: ((URL, AppTool) -> Void)? = nil
    @State private var showingIssues = false

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
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isScanning, !model.isCleaning, let first = urls.first else { return false }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                model.scan(folder: first)
                return true
            }
            return false
        }
        .sheet(isPresented: $model.showingReview) {
            DeveloperReviewSheet(model: model)
        }
        .sheet(isPresented: $showingIssues) {
            DeveloperIssuesSheet(issues: model.issues)
        }
        .onAppear {
            model.prepareDemoIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Developer Cleaner")
                .font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.artifacts.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter projects or folders", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear filter")
                        .accessibilityLabel("Clear filter")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(width: 220)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
            }
            HelpTip(
                text: "Scans a chosen folder for rebuildable build and dependency directories (node_modules, .build, DerivedData, Pods, target, .gradle, .next, .venv, __pycache__) and moves reviewed selections to Trash.",
                label: "About Developer Cleaner"
            )
        }
        .padding(.horizontal, 36)
        .padding(.top, 45)
        .padding(.bottom, 22)
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(model.quickFolders, id: \.url) { item in
                let isCurrent = model.rootURL?.standardizedFileURL.path == item.url.standardizedFileURL.path
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
                Button("Rescan") {
                    model.scan()
                }
                .controlSize(.small)
                .disabled(model.isScanning || model.isCleaning)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 12)
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Dismiss") { model.banner = nil }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning project folders…")
                    .font(.system(size: 14, weight: .medium))
                if let rootURL = model.rootURL {
                    Text(displayPath(rootURL.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report == nil {
            ContentUnavailableView {
                Label("Choose a projects folder to scan", systemImage: "hammer")
            } description: {
                Text("Find rebuildable build outputs and dependency caches across your local projects.")
            } actions: {
                HStack(spacing: 8) {
                    ForEach(model.quickFolders, id: \.url) { item in
                        Button("Scan \(item.title)") {
                            model.scan(folder: item.url)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Choose folder…") {
                        model.chooseFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.artifacts.isEmpty {
            ContentUnavailableView(
                "No build or dependency folders found",
                systemImage: "checkmark.circle",
                description: Text(model.rootURL.map { displayPath($0.path) } ?? "")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if model.visibleArtifacts.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visibleArtifacts) { item in
                                artifactRow(item)
                                Divider().padding(.leading, 30)
                            }
                        }
                        .padding(.horizontal, 36)
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    kindPill(title: "All", count: model.artifacts.count, totalBytes: model.report?.totalBytes ?? 0, isSelected: model.filterKind == nil) {
                        model.filterKind = nil
                    }
                    ForEach(DeveloperArtifactKind.allCases) { kind in
                        let matching = model.artifacts.filter { $0.kind == kind }
                        if !matching.isEmpty {
                            let kindBytes = matching.reduce(Int64(0)) { $0 + $1.byteCount }
                            kindPill(title: kind.title, count: matching.count, totalBytes: kindBytes, isSelected: model.filterKind == kind) {
                                model.filterKind = kind
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            Button("Select all \(model.visibleArtifacts.count)") {
                model.selectAllVisible()
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(model.visibleArtifacts.isEmpty)

            if !model.selectedIDs.isEmpty {
                Text("·").foregroundStyle(.secondary).font(.system(size: 11))
                Button("Clear selection") {
                    model.clearSelection()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 10)
    }

    private func kindPill(title: String, count: Int, totalBytes: Int64, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count) · \(bytes(totalBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Palette.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isSelected ? Palette.accent : .primary)
        }
        .buttonStyle(.plain)
    }

    private func artifactRow(_ item: DeveloperArtifact) -> some View {
        let isSelected = model.selectedIDs.contains(item.id)
        return HStack(spacing: 12) {
            Toggle(
                "Select \(item.projectName) \(item.kind.rawValue)",
                isOn: Binding(
                    get: { isSelected },
                    set: { _ in model.toggleSelection(item.id) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)

            Button {
                model.toggleSelection(item.id)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.projectName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(item.kind.rawValue)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 4))
                            Text(item.kind.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Text("\(displayPath(item.url.path)) · \(item.modifiedDate.formatted(.relative(presentation: .named)))")
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
                model.reveal(item)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(item.projectName) \(item.kind.rawValue) in Finder")
        }
        .padding(.vertical, 11)
        .background(isSelected ? Palette.accent.opacity(0.045) : Color.clear)
        .contextMenu {
            Button("Show in Finder") { model.reveal(item) }
            if let onHandoffFolder {
                Button("Open in Storage Map") { onHandoffFolder(item.url, .storageMap) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerSummary)
                .font(.system(size: 12, weight: model.selectedArtifacts.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.selectedArtifacts.isEmpty ? .secondary : .primary)
                .monospacedDigit()

            if !model.issues.isEmpty {
                Button("\(model.issues.count) skipped") {
                    showingIssues = true
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }

            Spacer()

            if model.isScanning {
                Button("Cancel") {
                    model.cancelScan()
                }
                .controlSize(.large)
            } else if model.report == nil {
                Button("Choose folder…") {
                    model.chooseFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Review…") {
                    model.presentReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedArtifacts.isEmpty || model.isCleaning)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
    }

    private var footerSummary: String {
        guard let report = model.report else {
            return "No folder scanned"
        }
        if !model.selectedArtifacts.isEmpty {
            return "\(model.selectedArtifacts.count) selected · \(bytes(model.selectedBytes))"
        }
        return "\(report.artifacts.count) build folders · \(bytes(report.totalBytes)) total"
    }
}

private struct DeveloperReviewSheet: View {
    @ObservedObject var model: DeveloperCleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 26))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Move build folders to Trash?")
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(model.pendingReviewItems.count) \(model.pendingReviewItems.count == 1 ? "folder" : "folders") · \(bytes(model.pendingReviewBytes)) on disk")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.pendingReviewItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.projectName)/\(item.kind.rawValue)")
                                    .font(.system(size: 13, weight: .medium))
                                Text(displayPath(item.url.path))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(bytes(item.byteCount))
                                .font(.system(size: 12))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 220)
            Divider()
            HStack {
                if model.isDemo {
                    Text("Demo · Simulates Trash removal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    model.cancelReview()
                }
                .keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) {
                    model.confirmTrash()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Palette.panel)
    }
}

private struct DeveloperIssuesSheet: View {
    let issues: [DeveloperScanIssue]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Skipped items")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayPath(issue.path))
                                .font(.system(size: 12, design: .monospaced))
                            Text(issue.message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 520, height: 320)
        .background(Palette.panel)
    }
}
