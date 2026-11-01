import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FileConverterModel: ObservableObject {
    @Published var mode: FileConversionMode = .images {
        didSet {
            guard mode != oldValue else { return }
            if isBusy { mode = oldValue; return }
            inputs = []; outputs = []; failures = []; notice = nil
            if isDemo { prepareDemo() }
        }
    }
    @Published var imageFormat: ConvertedImageFormat = .jpeg
    @Published var resizeImages = true
    @Published var maximumDimension = 2560
    @Published var quality = 0.8
    @Published var pdfDPI = 144
    @Published private(set) var inputs: [FileConversionInput] = []
    @Published private(set) var outputs: [FileConversionOutput] = []
    @Published private(set) var failures: [FileConversionFailure] = []
    @Published private(set) var outputFolder: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var isConverting = false
    @Published private(set) var progress: FileConversionProgress?
    @Published private(set) var notice: String?
    @Published var error: String?
    @Published var showFailures = false
    let isDemo: Bool
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var demoRoot: URL?

    init(isDemo: Bool = AppEnvironment.isDemo) { self.isDemo = isDemo }
    var canConvert: Bool { !isBusy && !inputs.isEmpty && outputFolder != nil }
    func loadIfNeeded() { if isDemo && demoRoot == nil { prepareDemo() } }
    func refresh() {
        guard !isBusy, !isDemo else { return }
        if inputs.isEmpty { chooseFiles() }
    }

    func chooseFiles() {
        guard !isBusy, !isDemo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = mode == .images ? [.image] : [.pdf]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        if outputFolder == nil, let first = panel.urls.first {
            outputFolder = first.deletingLastPathComponent().standardizedFileURL
        }
        addFiles(panel.urls)
    }
    func clearInputs() {
        guard !isBusy else { return }
        inputs = []; outputs = []; failures = []; notice = nil
    }
    func addFiles(_ urls: [URL]) {
        guard !isBusy else { return }
        let existing = Set(inputs.map(\.id))
        let candidates = urls.filter { !existing.contains($0.path) }
        guard inputs.count + candidates.count <= 100 else { error = "Add up to 100 files at a time."; return }
        generation = UUID()
        let token = generation
        isBusy = true
        outputs = []; failures = []; notice = nil
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                var accepted: [FileConversionInput] = []
                var failures: [FileConversionFailure] = []
                var seen = Set<String>()
                for url in candidates where seen.insert(url.path).inserted {
                    do { accepted.append(try FileConverter.inspect(url)) }
                    catch { failures.append(.init(name: url.lastPathComponent, message: error.localizedDescription)) }
                }
                return (accepted, failures)
            }.value
            guard let self, self.generation == token else { return }
            self.inputs.append(contentsOf: result.0)
            self.failures = result.1
            self.isBusy = false
            self.task = nil
        }
    }
    func chooseOutputFolder() {
        guard !isBusy, !isDemo else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "Choose"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }
    func setOutputFolder(_ folder: URL) { if !isBusy { outputFolder = folder } }
    func remove(_ input: FileConversionInput) {
        guard !isBusy else { return }
        inputs.removeAll { $0.id == input.id }; outputs = []; notice = nil
    }
    func move(_ input: FileConversionInput, by offset: Int) {
        guard !isBusy, let index = inputs.firstIndex(where: { $0.id == input.id }), inputs.indices.contains(index + offset) else { return }
        inputs.swapAt(index, index + offset); outputs = []; notice = nil
    }
    func convert() {
        guard canConvert, let outputFolder else { return }
        let options = FileConversionOptions(mode: mode, imageFormat: imageFormat,
                                            maximumDimension: resizeImages ? maximumDimension : nil,
                                            quality: quality, pdfDPI: pdfDPI)
        let inputs = self.inputs
        generation = UUID()
        let token = generation
        isBusy = true; isConverting = true; outputs = []; failures = []; notice = nil
        progress = .init(completed: 0, total: inputs.count, name: inputs.first?.name ?? "")
        task = Task { [weak self] in
            let result = await FileConverter().convert(inputs: inputs, options: options, outputFolder: outputFolder) { [weak self] update in
                await self?.updateProgress(update, token: token)
            }
            guard let self, self.generation == token else { return }
            self.outputs = result.outputs; self.failures = result.failures
            self.isBusy = false; self.isConverting = false; self.progress = nil; self.task = nil
            if result.isCancelled {
                self.notice = result.outputs.isEmpty ? "Conversion cancelled." : "Cancelled. \(result.outputs.count) exported files were kept."
            } else if !result.outputs.isEmpty {
                self.notice = "Exported \(result.outputs.count) \(result.outputs.count == 1 ? "file" : "files")."
            } else if !result.failures.isEmpty { self.notice = "No files were exported." }
        }
    }
    private func updateProgress(_ update: FileConversionProgress, token: UUID) {
        guard generation == token else { return }
        progress = update
    }
    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        if !isConverting { generation = UUID(); task = nil; isBusy = false; notice = "Cancelled." }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func shutdown() {
        generation = UUID(); task?.cancel(); task = nil
        if let root = demoRoot, root.path.hasPrefix("/private/tmp/MacTools-ConverterDemo-") {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func prepareDemo() {
        do {
            if demoRoot == nil {
                let root = URL(fileURLWithPath: "/private/tmp/MacTools-ConverterDemo-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Exports"), withIntermediateDirectories: true)
                demoRoot = root; outputFolder = root.appendingPathComponent("Exports")
            }
            guard let root = demoRoot else { return }
            let names = mode == .images ? ["Workspace.png", "Cover.png"] : ["First.pdf", "Second.pdf"]
            for (index, name) in names.enumerated() {
                let url = root.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    if mode == .images {
                        guard let context = CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                        context.setFillColor(CGColor(red: 0.12, green: 0.35 + Double(index) * 0.12, blue: 0.3, alpha: 1))
                        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 800))
                        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                        context.fill(CGRect(x: 180, y: 170, width: 920, height: 460))
                        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
                        try data.write(to: url)
                    } else {
                        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { continue }
                        context.beginPDFPage(nil)
                        context.setFillColor(CGColor(gray: 0.85 - Double(index) * 0.2, alpha: 1))
                        context.fill(CGRect(x: 60, y: 500, width: 492, height: 200))
                        context.endPDFPage(); context.closePDF()
                    }
                }
            }
            inputs = try names.map { try FileConverter.inspect(root.appendingPathComponent($0)) }
        } catch { self.error = error.localizedDescription }
    }
}
