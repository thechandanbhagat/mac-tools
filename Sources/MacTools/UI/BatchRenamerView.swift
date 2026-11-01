import QuickLook
import SwiftUI

struct BatchRenamerView: View {
    @ObservedObject var model: BatchRenamerModel
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text("Batch Renamer").font(.system(size: 28, weight: .semibold))
                    if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.files.isEmpty ? "Choose files…" : "Add files…", action: model.chooseFiles)
                        .disabled(model.isApplying)
                    if !model.files.isEmpty {
                        Button("Clear", action: model.clearFiles)
                            .disabled(model.isApplying)
                    }
                    HelpTip(text: "Choose local files, set a naming pattern, then review the preview. Extensions stay unchanged by default. Numbering follows filename order; dates use today’s date. Files stay in their folders. Undo restores the latest batch if its files are unchanged.", label: "About Batch Renamer")
                }
                if !model.files.isEmpty { options }
                if let error = model.previewError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 22)
            Divider()
            if let plan = model.plan, !plan.entries.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Original").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 24, height: 1)
                        Text("New name").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 48, height: 1)
                    }.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 36).padding(.vertical, 10)
                    Divider().padding(.horizontal, 36)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(plan.entries) { entry in
                                previewRow(entry)
                                Divider()
                            }
                        }.padding(.horizontal, 36)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(model.isPreviewing ? "Preparing preview…" : model.files.isEmpty ? "Choose files to rename" : "Adjust the names above", systemImage: "character.cursor.ibeam")
                } description: {
                    if model.files.isEmpty {
                        Text("Find and replace text, add prefixes or suffixes, or number local files in batch.")
                    }
                } actions: {
                    if model.files.isEmpty {
                        Button("Choose files…", action: model.chooseFiles)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isApplying)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .background(Palette.panel)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isApplying else { return false }
            let regularURLs = urls.filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            }
            guard !regularURLs.isEmpty else { return false }
            model.addFiles(regularURLs)
            return true
        }
        .quickLookPreview($quickLookURL)
        .task { model.loadIfNeeded() }
        .sheet(item: Binding(get: { model.pendingPlan }, set: { if $0 == nil { model.cancelReview() } })) { plan in
            BatchRenameConfirmation(plan: plan, isUndo: model.pendingIsUndo, isDemo: model.isDemo, cancel: model.cancelReview, confirm: model.confirm)
        }
        .alert("Unable to rename files", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                TextField("Find", text: $model.options.find).accessibilityLabel("Find text")
                TextField("Replace with", text: $model.options.replacement).accessibilityLabel("Replacement text")
            }
            HStack(spacing: 16) {
                TextField("Prefix", text: $model.options.prefix).accessibilityLabel("Filename prefix")
                TextField("Suffix", text: $model.options.suffix).accessibilityLabel("Filename suffix")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { numbering; Toggle("Add date", isOn: $model.options.includeDate); Toggle("Keep extension", isOn: $model.options.preserveExtension) }
                VStack(alignment: .leading, spacing: 12) { numbering; HStack(spacing: 22) { Toggle("Add date", isOn: $model.options.includeDate); Toggle("Keep extension", isOn: $model.options.preserveExtension) } }
            }.toggleStyle(.checkbox).font(.system(size: 12))
        }.textFieldStyle(.roundedBorder).disabled(model.isApplying)
    }

    private var numbering: some View {
        HStack(spacing: 8) {
            Toggle("Number from", isOn: $model.options.numbering)
            TextField("1", value: $model.options.startNumber, format: .number.grouping(.never))
                .frame(width: 56).disabled(!model.options.numbering).accessibilityLabel("Starting number")
        }
    }

    private func previewRow(_ entry: BatchRenameEntry) -> some View {
        HStack(spacing: 12) {
            Text(entry.source.lastPathComponent)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(entry.changes ? Palette.accent : Color.secondary.opacity(0.45))
                .frame(width: 24)
            Text(entry.destination.lastPathComponent)
                .fontWeight(entry.changes ? .medium : .regular)
                .foregroundStyle(entry.changes ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { quickLookURL = entry.source } label: { Image(systemName: "eye") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Quick Look").accessibilityLabel("Quick Look \(entry.source.lastPathComponent)")
                .frame(width: 20)
            Button { model.reveal(entry.source) } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Show in Finder").accessibilityLabel("Show \(entry.source.lastPathComponent) in Finder")
                .frame(width: 20)
            Button { model.removeFile(entry.source) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Remove from list").accessibilityLabel("Remove \(entry.source.lastPathComponent)")
                .frame(width: 20)
                .disabled(model.isApplying)
        }
        .font(.system(size: 13))
        .lineLimit(2)
        .truncationMode(.middle)
        .padding(.vertical, 12)
        .help(entry.source.path)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if !model.files.isEmpty {
                    Text("\(model.files.count) \(model.files.count == 1 ? "file" : "files")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if model.undoReceipt != nil {
                    Button("Undo Last Batch…", action: model.reviewUndo).disabled(model.isBusy)
                }
                Spacer()
                if model.isApplying {
                    ProgressView().controlSize(.small)
                    Text("Renaming…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if model.files.isEmpty {
                    Button("Choose files…", action: model.chooseFiles)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    if model.isPreviewing { ProgressView().controlSize(.small) }
                    if let plan = model.plan {
                        Text("\(plan.changes.count) \(plan.changes.count == 1 ? "change" : "changes")")
                            .font(.system(size: 12, weight: plan.changes.isEmpty ? .regular : .semibold))
                            .foregroundStyle(plan.changes.isEmpty ? .secondary : .primary)
                    }
                    Button("Review…", action: model.review).buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canApply)
                }
            }.padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }
    }
}

private struct BatchRenameConfirmation: View {
    let plan: BatchRenamePlan
    let isUndo: Bool
    let isDemo: Bool
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isUndo ? "Restore original names?" : "Rename \(plan.changes.count) \(plan.changes.count == 1 ? "file" : "files")?").font(.system(size: 21, weight: .semibold))
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                ForEach(plan.changes) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.source.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary)
                        Label(entry.destination.lastPathComponent, systemImage: "arrow.turn.down.right").font(.system(size: 13, weight: .medium))
                        Text(entry.source.deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(entry.source.path)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
            if isDemo { Text("Demo · Renaming is disabled.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button(isUndo ? "Restore Names" : "Rename", action: confirm).buttonStyle(.borderedProminent).disabled(isDemo)
            }
        }.padding(26).frame(width: 540).onExitCommand(perform: cancel)
    }
}
