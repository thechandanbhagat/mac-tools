import QuickLook
import SwiftUI

struct DuplicateFinderView: View {
    @ObservedObject var model: DuplicateFinderModel
    var onHandoffFile: ((URL, AppTool) -> Void)? = nil
    @State private var quickLookURL: URL?

    private var quickFolders: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ("Downloads", home.appendingPathComponent("Downloads")),
            ("Documents", home.appendingPathComponent("Documents")),
            ("Desktop", home.appendingPathComponent("Desktop")),
            ("Home", home)
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text("Duplicate Finder").font(.system(size: 28, weight: .semibold))
                    if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    HelpTip(text: "Files are compared by size and SHA-256 content hashes. Select copies to remove; at least one copy of each file must stay. Links, Finder aliases, files with resource forks, packages, hidden files, and cloud locations are skipped. Contents are checked again before moving to Trash.", label: "About Duplicate Finder")
                }
                HStack(spacing: 8) {
                    ForEach(quickFolders, id: \.0) { title, url in
                        Button(title) { model.setRoot(url) }
                            .controlSize(.small)
                            .disabled(model.isBusy || model.isDemo)
                    }
                    Button(model.rootURL == nil ? "Choose folder…" : "Change…", action: model.chooseFolder)
                        .controlSize(.small)
                        .disabled(model.isBusy || model.isDemo)
                    if let url = model.rootURL {
                        Text(displayPath(url.path))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    }
                    Spacer()
                }
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 18)
            Divider()
            if !model.groups.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Filter duplicate files", text: $model.query).textFieldStyle(.plain)
                            if !model.query.isEmpty {
                                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel("Clear filter")
                            }
                        }
                        .font(.system(size: 12))
                        .padding(8)
                        .frame(maxWidth: 260)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))

                        Spacer()
                        Button("Select duplicates") { model.selectDuplicates() }
                            .buttonStyle(.link).font(.system(size: 11)).disabled(model.isBusy)
                        if !model.selectedIDs.isEmpty {
                            Text("·").foregroundStyle(.secondary).font(.system(size: 11))
                            Button("Clear selection") { model.clearSelection() }
                                .buttonStyle(.link).font(.system(size: 11)).disabled(model.isBusy)
                        }
                    }
                    .padding(.horizontal, 36).padding(.vertical, 12)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.filteredGroups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("\(group.files.count) copies").font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text("\(bytes(group.byteCount)) each").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    ForEach(group.files) { file in row(file, group: group) }
                                }
                                .padding(14)
                                .background(Palette.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.padding(.horizontal, 36).padding(.vertical, 16)
                    }
                }
            } else if model.isScanning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for duplicates…").font(.system(size: 14, weight: .medium))
                    if let url = model.rootURL {
                        Text(displayPath(url.path)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(model.hasScanned ? "No duplicates found" : "Choose a folder to scan", systemImage: "doc.on.doc")
                } description: {
                    Text(model.hasScanned ? "No identical files were found in this folder." : "Compare files by size and SHA-256 content digest.")
                } actions: {
                    if !model.hasScanned {
                        Button("Choose folder…", action: model.chooseFolder)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || model.isDemo)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .background(Palette.panel)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, !model.isDemo, let first = urls.first else { return false }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                model.setRoot(first)
                return true
            }
            return false
        }
        .quickLookPreview($quickLookURL)
        .task { model.loadIfNeeded() }
        .sheet(item: Binding(get: { model.pendingRequest }, set: { if $0 == nil { model.cancelReview() } })) { request in
            DuplicateConfirmation(request: request, isDemo: model.isDemo, cancel: model.cancelReview, confirm: model.confirmTrash)
        }
        .sheet(isPresented: $model.showIssues) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Scan notices").font(.system(size: 22, weight: .semibold))
                ScrollView { VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.message).font(.system(size: 13))
                            Text(issue.path).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240)
                HStack { Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction) }
            }.padding(26).frame(width: 560)
        }
        .alert("Duplicate Finder", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func row(_ file: DuplicateFile, group: DuplicateGroup) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.selectedIDs.contains(file.id) }, set: { _ in model.toggle(file, in: group) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(displayPath(file.url.deletingLastPathComponent().path))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }.toggleStyle(.checkbox).disabled(!model.canSelect(file, in: group))
                .accessibilityLabel("Move \(file.url.path) to Trash").help(file.url.path)
            Spacer(minLength: 8)
            Button { quickLookURL = file.url } label: { Image(systemName: "eye") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quick Look").accessibilityLabel("Quick Look \(file.name)")
            Button { model.reveal(file) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Show in Finder").accessibilityLabel("Show \(file.name) in Finder")
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Quick Look") { quickLookURL = file.url }
            Button("Show in Finder") { model.reveal(file) }
            if let onHandoffFile {
                Divider()
                Button("Inspect Checksums") { onHandoffFile(file.url, .checksums) }
                Button("Inspect Metadata") { onHandoffFile(file.url, .metadata) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if !model.groups.isEmpty {
                    Text("\(model.groups.count) \(model.groups.count == 1 ? "group" : "groups")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if !model.issues.isEmpty {
                    Button { model.showIssues = true } label: { Label("\(model.issues.count) notices", systemImage: "exclamationmark.circle") }.buttonStyle(.link).font(.system(size: 12))
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    if model.isTrashing { Text("Checking and moving…").font(.system(size: 12)).foregroundStyle(.secondary) }
                    else { Button("Cancel scan", action: model.cancelScan) }
                } else if model.rootURL == nil {
                    Button("Choose folder…", action: model.chooseFolder)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    if !model.selectedIDs.isEmpty {
                        Text("\(model.selectedFiles.count) selected · \(bytes(model.selectedBytes))")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Scan again (Command-R)").accessibilityLabel("Scan again").disabled(model.rootURL == nil)
                    Button("Review…", action: model.review).buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selectedIDs.isEmpty)
                }
            }.padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }
    }
}

private struct DuplicateConfirmation: View {
    let request: DuplicateTrashRequest
    let isDemo: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Move \(request.files.count) \(request.files.count == 1 ? "file" : "files") to Trash?").font(.system(size: 21, weight: .semibold))
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                ForEach(request.files) { file in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.system(size: 13, weight: .medium))
                            Text(file.url.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle).help(file.url.path)
                        }
                        Spacer()
                        Text(bytes(file.snapshot.allocatedBytes)).font(.system(size: 12)).monospacedDigit()
                    }
                }
            } }.frame(maxHeight: 220)
            Text("At least one copy of each file will stay. You can restore removed copies from Trash in Finder.").font(.system(size: 12)).foregroundStyle(.secondary)
            if isDemo { Text("Demo · Moving files is disabled.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Text(bytes(request.byteCount)).font(.system(size: 13)).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button("Move to Trash", role: .destructive, action: confirm).buttonStyle(.borderedProminent).disabled(isDemo)
            }
        }.padding(26).frame(width: 560).onExitCommand(perform: cancel)
    }
}
