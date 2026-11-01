import AppKit
import SwiftUI

@MainActor
protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func candidate() -> ClipboardCandidate?
    func write(_ content: ClipboardContent) -> Bool
}

@MainActor
final class SystemClipboardAccess: ClipboardAccess {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func candidate() -> ClipboardCandidate? {
        let pasteboard = NSPasteboard.general
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !ClipboardCandidate.excludes(types: types) else { return nil }
        // Never ask providers to materialize file promises, URLs, or arbitrary types.
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return ClipboardCandidate(types: types, text: nil, imageData: data)
        }
        return ClipboardCandidate(types: types, text: pasteboard.string(forType: .string), imageData: nil)
    }
    func write(_ content: ClipboardContent) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content {
        case .text(let text): return pasteboard.setString(text, forType: .string)
        case .image(let data, _, _): return pasteboard.setData(data, forType: .png)
        }
    }
}

@MainActor
final class ClipboardHistoryModel: ObservableObject {
    @Published private(set) var history = ClipboardHistory()
    @Published private(set) var isMonitoring = false
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var notice: String?
    @Published var error: String?
    let isDemo: Bool
    private let access: any ClipboardAccess
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastChangeCount = 0

    init(isDemo: Bool = AppEnvironment.isDemo, access: (any ClipboardAccess)? = nil) {
        self.isDemo = isDemo
        self.access = access ?? SystemClipboardAccess()
        if isDemo {
            if let image = Self.demoImage() { history.insert(image) }
            history.insert(.text("A quiet workspace, ready for the next idea."))
            history.insert(.text("https://developer.apple.com/documentation/"))
            history.insert(.text("Project notes\nReview the new layout and prepare the final images."))
            selectedID = history.entries.first?.id
        }
    }
    var isBusy: Bool { false }
    var entries: [ClipboardEntry] {
        history.entries.filter { query.isEmpty || $0.content.searchableText.localizedCaseInsensitiveContains(query) }
    }
    var selectedEntry: ClipboardEntry? { history.entries.first { $0.id == selectedID } }

    func start() {
        guard !isMonitoring, !isDemo else { return }
        lastChangeCount = access.changeCount // Start with the next copy, never ingest the existing clipboard.
        generation = UUID()
        let token = generation
        isMonitoring = true
        notice = nil
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, self.generation == token, self.isMonitoring, !Task.isCancelled else { return }
                await self.captureChange(token: token)
            }
        }
    }
    func pause() {
        generation = UUID()
        task?.cancel()
        task = nil
        isMonitoring = false
    }
    func captureChange(token: UUID? = nil) async {
        guard isMonitoring, !isDemo else { return }
        let expected = token ?? generation
        let count = access.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // Types and payload arrive through separate pasteboard reads. Discard a mixed
        // generation so a newly concealed item cannot inherit the previous item's types.
        guard let candidate = access.candidate(), access.changeCount == count else { return }
        let content = await Task.detached(priority: .utility) { candidate.sanitized() }.value
        guard generation == expected, isMonitoring, let content else { return }
        history.insert(content)
        if selectedID == nil { selectedID = history.entries.first?.id }
        if !history.entries.contains(where: { $0.id == selectedID }) { selectedID = history.entries.first?.id }
    }
    func copySelected() {
        guard !isDemo, let item = selectedEntry else { return }
        copy(item)
    }
    func copy(_ item: ClipboardEntry) {
        guard !isDemo else { return }
        if access.write(item.content) {
            lastChangeCount = access.changeCount
            notice = "Copied."
        } else { error = "Couldn’t copy this item. Try again." }
    }
    func removeSelected() {
        guard let selectedID else { return }
        history.remove(id: selectedID)
        self.selectedID = entries.first?.id
        notice = nil
    }
    func clear() {
        // Invalidate a capture already being decoded so Clear stays clear.
        let resume = isMonitoring
        pause()
        history.clear()
        selectedID = nil
        notice = nil
        if resume { start() }
    }
    func refresh() {} // Clipboard is event-polled only after explicit Start.
    func shutdown() { pause(); history.clear(); selectedID = nil }

    private static func demoImage() -> ClipboardContent? {
        guard let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        context.setFillColor(CGColor(red: 0.12, green: 0.4, blue: 0.33, alpha: 1)); context.fill(CGRect(x: 70, y: 330, width: 300, height: 70))
        context.setFillColor(CGColor(gray: 0.72, alpha: 1))
        for (index, width) in [610, 540, 580, 360].enumerated() {
            context.fill(CGRect(x: 70, y: 255 - index * 48, width: width, height: 18))
        }
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return .image(data, width: 800, height: 500)
    }
}
