import QuickLook
import SwiftUI

struct MetadataScrubberView: View {
    @ObservedObject var model: MetadataScrubberModel
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeBar
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
            model.addFiles(urls)
            return true
        }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $model.showingConfirmation) {
            MetadataScrubConfirmationSheet(
                count: model.records.count,
                stripInPlace: model.stripXattrsInPlace,
                onCancel: model.cancelScrub,
                onConfirm: model.confirmScrub
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Metadata").font(.system(size: 28, weight: .semibold))
            if model.isDemo {
                Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add files…") {
                model.chooseFiles()
            }
            .disabled(model.isBusy)

            if !model.records.isEmpty {
                Button("Clear") {
                    model.clearFiles()
                }
                .disabled(model.isBusy)
            }

            HelpTip(
                text: "Inspects local images, PDFs, and files for GPS coordinates, camera EXIF data, PDF document properties, and macOS extended attributes (such as quarantine or download URLs). Clean exports create new `-clean` copies without overwriting originals.",
                label: "About Metadata"
            )
        }
        .padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 22)
    }

    private var modeBar: some View {
        HStack(spacing: 14) {
            Picker("Action", selection: $model.stripXattrsInPlace) {
                Text("Export clean copies (strips EXIF, GPS, PDF info & xattrs)").tag(false)
                Text("Remove extended attributes only").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
            Spacer()
        }
        .padding(.horizontal, 36).padding(.vertical, 12)
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if let firstExport = model.exportedURLs.first {
                Button("Show in Finder") {
                    model.reveal(firstExport)
                }
                .buttonStyle(.link).font(.system(size: 12))
            }
            Button("Dismiss") { model.banner = nil }
                .buttonStyle(.link).font(.system(size: 12))
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.records.isEmpty {
            ContentUnavailableView {
                Label("Choose or drop files to inspect metadata", systemImage: "eye.trianglebadge.exclamationmark")
            } description: {
                Text("Inspect and scrub GPS location, camera EXIF, PDF author info, and macOS quarantine attributes.")
            } actions: {
                Button("Choose files…") {
                    model.chooseFiles()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                fileList
                    .frame(width: 280)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.records) { record in
                    let isSelected = model.selectedRecord?.id == record.id
                    HStack(spacing: 10) {
                        Button {
                            model.selectedID = record.id
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.name)
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(record.kind.rawValue) · \(record.fields.count) \(record.fields.count == 1 ? "entry" : "entries")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.removeFile(id: record.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from list")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(isSelected ? Palette.accent.opacity(0.10) : Color.clear)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let record = model.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 18, weight: .semibold))
                            Text("\(displayPath(record.url.path)) · \(bytes(record.byteCount))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            quickLookURL = record.url
                        } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.borderless)
                        .help("Quick Look")
                        .accessibilityLabel("Quick Look \(record.name)")

                        Button {
                            model.reveal(record.url)
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        .accessibilityLabel("Show \(record.name) in Finder")
                    }

                    Divider()

                    if record.fields.isEmpty {
                        Text("No EXIF, GPS, document, or extended attributes found on this file.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(MetadataCategory.allCases) { category in
                            let categoryFields = record.fields.filter { $0.category == category }
                            if !categoryFields.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(category.rawValue)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(category == .gps ? .orange : Palette.accent)
                                    ForEach(categoryFields) { field in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(field.key)
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .frame(width: 190, alignment: .leading)
                                            Text(field.value)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(.vertical, 3)
                                    }
                                }
                                .padding(12)
                                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.records.isEmpty
                 ? "No files selected"
                 : "\(model.records.count) \(model.records.count == 1 ? "file" : "files") · \(model.recordsWithMetadataCount) with metadata")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if model.records.isEmpty {
                Button("Choose files…") {
                    model.chooseFiles()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(model.stripXattrsInPlace ? "Remove Extended Attributes…" : "Export Clean Copies…") {
                    model.requestScrub()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 18)
    }
}

private struct MetadataScrubConfirmationSheet: View {
    let count: Int
    let stripInPlace: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(stripInPlace
                 ? "Remove extended attributes from \(count) \(count == 1 ? "file" : "files")?"
                 : "Export \(count) clean \(count == 1 ? "copy" : "copies")?")
                .font(.system(size: 20, weight: .semibold))
            Text(stripInPlace
                 ? "Removes macOS extended attributes (such as quarantine flags and download URLs) directly from the selected files."
                 : "Creates new `-clean` files alongside the originals with GPS coordinates, EXIF camera data, PDF document properties, and extended attributes removed. Original files are untouched.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(stripInPlace ? "Remove Attributes" : "Export Clean Copies", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(26)
        .frame(width: 480)
        .background(Palette.panel)
    }
}
