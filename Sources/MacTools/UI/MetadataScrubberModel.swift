import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class MetadataScrubberModel: ObservableObject {
    @Published private(set) var records: [MetadataRecord] = []
    @Published private(set) var issues: [MetadataIssue] = []
    @Published private(set) var exportedURLs: [URL] = []
    @Published var selectedID: String?
    @Published var stripXattrsInPlace = false
    @Published private(set) var isBusy = false
    @Published var showingConfirmation = false
    @Published var banner: String?

    let isDemo: Bool
    private var fileURLs: [URL] = []
    private var demoRoot: URL?

    init(isDemo: Bool = AppEnvironment.isDemo) {
        self.isDemo = isDemo
    }

    var selectedRecord: MetadataRecord? {
        if let selectedID, let match = records.first(where: { $0.id == selectedID }) {
            return match
        }
        return records.first
    }

    var recordsWithMetadataCount: Int {
        records.filter(\.hasPrivacyMetadata).count
    }

    func prepareDemoIfNeeded() {
        guard isDemo, records.isEmpty, !isBusy else { return }
        let root = URL(fileURLWithPath: "/private/tmp/MacToolsMetadataDemo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        removeDemoFiles()
        demoRoot = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let photoURL = root.appendingPathComponent("FieldPhoto.jpg")
        if let context = CGContext(
            data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() {
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) {
                let props: [CFString: Any] = [
                    kCGImagePropertyExifDictionary: [
                        kCGImagePropertyExifDateTimeOriginal: "2026:10:15 14:22:10",
                        kCGImagePropertyExifLensModel: "35mm f/1.4"
                    ],
                    kCGImagePropertyGPSDictionary: [
                        kCGImagePropertyGPSLatitude: 37.7749,
                        kCGImagePropertyGPSLatitudeRef: "N",
                        kCGImagePropertyGPSLongitude: 122.4194,
                        kCGImagePropertyGPSLongitudeRef: "W"
                    ],
                    kCGImagePropertyTIFFDictionary: [
                        kCGImagePropertyTIFFMake: "Apple",
                        kCGImagePropertyTIFFModel: "iPhone 16 Pro"
                    ]
                ]
                CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
                CGImageDestinationFinalize(dest)
                try? (data as Data).write(to: photoURL)
            }
        }
        let quarantine = "0081;67100000;Safari;12345678-1234-1234-1234-1234567890AB"
        _ = quarantine.withCString { ptr in
            setxattr(photoURL.path, "com.apple.quarantine", ptr, strlen(ptr), 0, XATTR_NOFOLLOW)
        }
        addFiles([photoURL])
    }

    func chooseFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Files to Inspect Metadata"
        panel.prompt = "Inspect"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    func addFiles(_ urls: [URL]) {
        guard !isBusy else { return }
        var seen = Set(fileURLs.map { $0.standardized.path })
        for url in urls {
            let std = url.standardized
            if seen.insert(std.path).inserted {
                fileURLs.append(std)
            }
        }
        refresh()
    }

    func removeFile(id: String) {
        guard !isBusy else { return }
        fileURLs.removeAll { $0.standardized.path == id }
        records.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = records.first?.id
        }
    }

    func clearFiles() {
        guard !isBusy else { return }
        fileURLs = []
        records = []
        issues = []
        exportedURLs = []
        selectedID = nil
        banner = nil
    }

    func refresh() {
        guard !isBusy else { return }
        let urls = fileURLs
        guard !urls.isEmpty else {
            records = []
            issues = []
            selectedID = nil
            return
        }
        isBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MetadataScrubber.inspect(urls: urls)
            }.value
            self.isBusy = false
            self.records = result.records
            self.issues = result.issues
            if let current = self.selectedID, result.records.contains(where: { $0.id == current }) {
                // Keep selection
            } else {
                self.selectedID = result.records.first?.id
            }
        }
    }

    func requestScrub() {
        guard !records.isEmpty, !isBusy else { return }
        showingConfirmation = true
    }

    func cancelScrub() {
        showingConfirmation = false
    }

    func confirmScrub() {
        guard !records.isEmpty, !isBusy else {
            showingConfirmation = false
            return
        }
        showingConfirmation = false
        let currentRecords = records
        let inPlaceXattrs = stripXattrsInPlace
        isBusy = true
        banner = nil

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                MetadataScrubber.scrubFiles(
                    records: currentRecords,
                    stripExtendedAttributesInPlace: inPlaceXattrs
                )
            }.value
            self.isBusy = false
            self.records = outcome.updatedRecords
            self.exportedURLs = outcome.exportedURLs
            self.issues = outcome.issues
            if inPlaceXattrs {
                self.banner = "Removed extended attributes from \(outcome.updatedRecords.count) \(outcome.updatedRecords.count == 1 ? "file" : "files")."
            } else if !outcome.exportedURLs.isEmpty {
                self.banner = "Exported \(outcome.exportedURLs.count) clean \(outcome.exportedURLs.count == 1 ? "copy" : "copies") without EXIF, GPS, document, or extended attributes."
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeDemoFiles() {
        guard let demoRoot,
              demoRoot.lastPathComponent.hasPrefix("MacToolsMetadataDemo-"),
              demoRoot.deletingLastPathComponent().path == "/private/tmp" else { return }
        try? FileManager.default.removeItem(at: demoRoot)
        self.demoRoot = nil
    }

    func shutdown() {
        showingConfirmation = false
        removeDemoFiles()
    }
}
