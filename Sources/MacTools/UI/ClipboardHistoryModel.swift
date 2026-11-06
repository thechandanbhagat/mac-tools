import AppKit
import SwiftUI

@MainActor
protocol ClipboardAccess: AnyObject {
    var changeCount: Int { get }
    func candidate() -> ClipboardCandidate?
    func write(_ content: ClipboardContent) -> Bool
    func writeSensitive(_ content: ClipboardContent) -> Bool
    func clearSensitive()
}

extension ClipboardAccess {
    // A provider must explicitly support concealed writes; never downgrade a secret.
    func writeSensitive(_ content: ClipboardContent) -> Bool { false }
    func clearSensitive() {}
}

/// An injectable boundary keeps clipboard policy tests independent of the host daemon.
@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
    func writeItem(_ item: NSPasteboardItem) -> Bool
}

@MainActor
private final class SystemClipboardPasteboard: ClipboardPasteboard {
    private let pasteboard = NSPasteboard.general
    var changeCount: Int { pasteboard.changeCount }
    var types: [NSPasteboard.PasteboardType]? { pasteboard.types }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { pasteboard.data(forType: type) }
    func string(forType type: NSPasteboard.PasteboardType) -> String? { pasteboard.string(forType: type) }
    @discardableResult func clearContents() -> Int { pasteboard.clearContents() }
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setString(string, forType: type)
    }
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        pasteboard.setData(data, forType: type)
    }
    func writeItem(_ item: NSPasteboardItem) -> Bool { pasteboard.writeObjects([item]) }
}

@MainActor
final class SystemClipboardAccess: ClipboardAccess {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let ownershipType = NSPasteboard.PasteboardType("com.chandan.mac-tools.sensitive-token")
    private let pasteboard: any ClipboardPasteboard
    private let sensitiveLifetime: Duration
    private var sensitiveLease: SensitiveClipboardLease?
    private var sensitiveCleanup: Task<Void, Never>?

    init(pasteboard: (any ClipboardPasteboard)? = nil, sensitiveLifetime: Duration = .seconds(30)) {
        self.pasteboard = pasteboard ?? SystemClipboardPasteboard()
        self.sensitiveLifetime = sensitiveLifetime
    }

    var changeCount: Int { pasteboard.changeCount }
    func candidate() -> ClipboardCandidate? {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !ClipboardCandidate.excludes(types: types) else { return nil }
        // Never ask providers to materialize file promises, URLs, or arbitrary types.
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return ClipboardCandidate(types: types, text: nil, imageData: data)
        }
        return ClipboardCandidate(types: types, text: pasteboard.string(forType: .string), imageData: nil)
    }
    func write(_ content: ClipboardContent) -> Bool {
        cancelSensitiveCleanup()
        pasteboard.clearContents()
        switch content {
        case .text(let text): return pasteboard.setString(text, forType: .string)
        case .image(let data, _, _): return pasteboard.setData(data, forType: .png)
        }
    }

    func writeSensitive(_ content: ClipboardContent) -> Bool {
        let item = NSPasteboardItem()
        let payloadSet: Bool
        switch content {
        case .text(let text): payloadSet = item.setString(text, forType: .string)
        case .image(let data, _, _): payloadSet = item.setData(data, forType: .png)
        }
        let token = UUID().uuidString
        guard payloadSet,
              item.setData(Data(), forType: Self.concealedType),
              item.setString(token, forType: Self.ownershipType) else { return false }

        cancelSensitiveCleanup()
        pasteboard.clearContents()
        // The payload and privacy marker become readable together. Clipboard capture
        // can never observe a generation containing an unmarked secret from this write.
        let written = pasteboard.writeItem(item)
        let lease = SensitiveClipboardLease(pasteboard: pasteboard, changeCount: pasteboard.changeCount,
                                           token: token, ownershipType: Self.ownershipType)
        guard written else {
            // A provider that partially committed before reporting failure must
            // not leave our secret behind without a scheduled expiry.
            lease.clearIfOwned()
            return false
        }
        sensitiveLease = lease
        let lifetime = sensitiveLifetime
        // Capture no payload or writer. The scheduled expiry remains alive even if a
        // temporary caller releases this ClipboardAccess immediately after writing.
        sensitiveCleanup = Task { @MainActor in
            do { try await Task.sleep(for: lifetime) } catch { return }
            guard !Task.isCancelled else { return }
            lease.clearIfOwned()
        }
        return true
    }

    func clearSensitive() {
        sensitiveLease?.clearIfOwned()
        cancelSensitiveCleanup()
    }

    private func cancelSensitiveCleanup() {
        sensitiveCleanup?.cancel()
        sensitiveCleanup = nil
        sensitiveLease = nil
    }
}

@MainActor
private struct SensitiveClipboardLease {
    let pasteboard: any ClipboardPasteboard
    let changeCount: Int
    let token: String
    let ownershipType: NSPasteboard.PasteboardType

    func clearIfOwned() {
        guard pasteboard.changeCount == changeCount,
              pasteboard.types?.contains(SystemClipboardAccess.concealedType) == true,
              pasteboard.string(forType: ownershipType) == token else { return }
        pasteboard.clearContents()
    }
}

@MainActor
final class ClipboardHistoryModel: ObservableObject {
    @Published private(set) var history: ClipboardHistory
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
    private var sensitiveContents: [ClipboardContent] = []

    init(isDemo: Bool = AppEnvironment.isDemo, access: (any ClipboardAccess)? = nil,
         captureOnLaunch: Bool = false, historyLimit: Int = 100) {
        self.isDemo = isDemo
        self.access = access ?? SystemClipboardAccess()
        self.history = ClipboardHistory(maximumCount: min(500, max(1, historyLimit)))
        if isDemo {
            if let image = Self.demoImage() { history.insert(image) }
            history.insert(.text("A quiet workspace, ready for the next idea."))
            history.insert(.text("https://developer.apple.com/documentation/"))
            history.insert(.text("Project notes\nReview the new layout and prepare the final images."))
            selectedID = history.entries.first?.id
        }
        if captureOnLaunch, !isDemo { start() }
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
        guard generation == expected, isMonitoring, let content,
              !sensitiveContents.contains(content) else { return }
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
        // A menu action may still hold an entry removed by a just-completed
        // sensitivity change. Require the vault's protected copy path instead.
        guard !sensitiveContents.contains(item.content) else {
            error = "This item is protected in Key Vault. Copy it from there."
            return
        }
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
    func setHistoryLimit(_ count: Int) {
        // A capture still being decoded inserts against the latest limit, so this
        // does not need to restart monitoring or discard the next clipboard change.
        history.setMaximumCount(min(500, max(1, count)))
        if !history.entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }
    func setSensitiveContents(_ contents: [ClipboardContent]) {
        sensitiveContents = contents
        let removedIDs = history.entries.filter { contents.contains($0.content) }.map(\.id)
        guard !removedIDs.isEmpty else { return }
        var updated = history
        for id in removedIDs { updated.remove(id: id) }
        history = updated
        if !history.entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
        }
    }
    func refresh() {} // Clipboard is event-polled only while capture is enabled.
    func shutdown() { pause(); history.clear(); sensitiveContents = []; selectedID = nil }

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
