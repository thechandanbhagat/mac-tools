import QuickLook
import SwiftUI

struct FileConverterView: View {
    @ObservedObject var model: FileConverterModel
    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("File Converter").font(.system(size: 28, weight: .semibold))
                if model.isDemo { Text("Demo").font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                HelpTip(text: "Export local images as JPEG, PNG, or TIFF, combine PDFs in list order, or reduce PDF image quality. Originals are kept and existing exports are never overwritten. Images are oriented correctly and their metadata is removed; JPEG uses a white background for transparency. Animated and multipage images, encrypted PDFs, cloud files, and package contents are skipped. Up to 100 files totaling 512 MB, 256 MB per input, and 1,000 PDF pages are supported. Compression can produce a larger file; exported sizes are shown.", label: "About file converter")
            }.padding(.horizontal, 36).padding(.top, 45).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Picker("Conversion", selection: $model.mode) {
                        ForEach(FileConversionMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Conversion type").disabled(model.isBusy)
                    settings.disabled(model.isBusy)
                    if model.mode == .compressPDF {
                        Label("Compression flattens each page. Searchable text, links, forms, and annotations are lost in the exported copy.", systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if !model.inputs.isEmpty {
                            Text("\(model.inputs.count) \(model.inputs.count == 1 ? "file" : "files")").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add files…") { model.chooseFiles() }.disabled(model.isBusy || model.isDemo)
                        if !model.inputs.isEmpty {
                            Button("Clear") { model.clearInputs() }.disabled(model.isBusy || model.isDemo)
                        }
                    }
                    if model.inputs.isEmpty {
                        ContentUnavailableView("Choose files to convert", systemImage: model.mode == .images ? "photo.on.rectangle" : "doc.on.doc")
                            .frame(minHeight: 150)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.inputs.enumerated()), id: \.element.id) { index, input in
                                inputRow(input, index: index)
                                if index < model.inputs.count - 1 { Divider() }
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.outputFolder?.lastPathComponent ?? "Output folder").font(.system(size: 13))
                            if let url = model.outputFolder {
                                Text(url.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(url.path)
                            }
                        }
                        Spacer()
                        Button("Choose…") { model.chooseOutputFolder() }.disabled(model.isBusy || model.isDemo)
                    }
                    if !model.outputs.isEmpty {
                        Divider()
                        VStack(spacing: 14) {
                            ForEach(model.outputs) { output in
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle").foregroundStyle(Palette.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(output.url.lastPathComponent).font(.system(size: 13)).lineLimit(1)
                                        Text(outputSize(output)).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button { model.reveal(output.url) } label: { Image(systemName: "arrow.up.forward.square") }
                                        .buttonStyle(.plain).help("Show export in Finder").accessibilityLabel("Show \(output.url.lastPathComponent) in Finder")
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 36).padding(.bottom, 24)
            }
            Divider()
            HStack(spacing: 14) {
                if !model.failures.isEmpty {
                    Button { model.showFailures = true } label: {
                        Label("\(model.failures.count) \(model.failures.count == 1 ? "issue" : "issues")", systemImage: "exclamationmark.circle")
                    }.buttonStyle(.link)
                }
                if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(.secondary) }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    if let progress = model.progress {
                        Text("\(progress.completed) of \(progress.total)").font(.system(size: 12)).monospacedDigit().help(progress.name)
                    }
                    Button("Cancel") { model.cancel() }.controlSize(.large)
                } else if model.inputs.isEmpty {
                    Button("Choose files…") { model.chooseFiles() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isDemo)
                } else if model.outputFolder == nil {
                    Button("Choose output folder…") { model.chooseOutputFolder() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isDemo)
                } else {
                    Button("Convert") { model.convert() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canConvert)
                }
            }.padding(.horizontal, 36).padding(.vertical, 18).frame(minHeight: 68)
        }.background(Palette.panel)
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isBusy, !model.isDemo else { return false }
                let regularURLs = urls.filter { url in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
                }
                guard !regularURLs.isEmpty else { return false }
                if model.outputFolder == nil, let first = regularURLs.first {
                    model.setOutputFolder(first.deletingLastPathComponent().standardized)
                }
                model.addFiles(regularURLs)
                return true
            }
            .quickLookPreview($quickLookURL)
            .task { model.loadIfNeeded() }
            .alert("File converter", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .sheet(isPresented: $model.showFailures) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Conversion issues").font(.system(size: 22, weight: .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(model.failures) { failure in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(failure.name).font(.system(size: 13, weight: .medium))
                                    Text(failure.message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 240)
                    HStack { Spacer(); Button("Done") { model.showFailures = false }.keyboardShortcut(.defaultAction) }
                }.padding(28).frame(width: 480)
            }
    }

    @ViewBuilder private var settings: some View {
        if model.mode == .images {
            HStack(alignment: .top, spacing: 24) {
                Picker("Format", selection: $model.imageFormat) {
                    ForEach(ConvertedImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 160)
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Resize", isOn: $model.resizeImages)
                    if model.resizeImages {
                        HStack {
                            TextField("Longest edge", value: $model.maximumDimension, format: .number.grouping(.never))
                                .frame(width: 70).accessibilityLabel("Longest edge in pixels")
                            Text("px max").foregroundStyle(.secondary)
                        }.font(.system(size: 12))
                    }
                }
                if model.imageFormat == .jpeg { quality.frame(maxWidth: 190) }
                Spacer(minLength: 0)
            }
        } else if model.mode == .compressPDF {
            HStack(spacing: 24) {
                Picker("Resolution", selection: $model.pdfDPI) {
                    Text("72 dpi").tag(72); Text("144 dpi").tag(144); Text("216 dpi").tag(216)
                }.frame(width: 190)
                quality.frame(maxWidth: 220)
                Spacer(minLength: 0)
            }
        }
    }
    private var quality: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Quality").font(.system(size: 12)).foregroundStyle(.secondary)
            Slider(value: $model.quality, in: 0.1...1, step: 0.1).accessibilityLabel("Image quality")
                .accessibilityValue("\(Int(model.quality * 100)) percent")
        }
    }
    private func inputRow(_ input: FileConversionInput, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.mode == .images ? "photo" : "doc.richtext").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(input.name).font(.system(size: 13)).lineLimit(1).help(input.url.path)
                Text(bytes(input.byteCount)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.mode == .combinePDF {
                Button { model.move(input, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).disabled(index == 0 || model.isBusy).help("Move earlier").accessibilityLabel("Move \(input.name) earlier")
                Button { model.move(input, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).disabled(index == model.inputs.count - 1 || model.isBusy).help("Move later").accessibilityLabel("Move \(input.name) later")
            }
            Button { quickLookURL = input.url } label: { Image(systemName: "eye") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quick Look").accessibilityLabel("Quick Look \(input.name)")
            Button { model.remove(input) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).disabled(model.isBusy).help("Remove file").accessibilityLabel("Remove \(input.name)")
        }.padding(.vertical, 12)
    }
    private func outputSize(_ output: FileConversionOutput) -> String {
        guard model.mode == .compressPDF, output.originalBytes > 0 else { return bytes(output.byteCount) }
        let change = Int((Double(output.byteCount) / Double(output.originalBytes) - 1) * 100)
        if change == 0 { return "\(bytes(output.byteCount)) · Same size" }
        return "\(bytes(output.byteCount)) · \(abs(change))% \(change > 0 ? "larger" : "smaller")"
    }
}
