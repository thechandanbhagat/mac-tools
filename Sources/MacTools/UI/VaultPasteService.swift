import AppKit
import ApplicationServices
import CoreGraphics

/// The destination is captured before the picker takes keyboard focus. It contains
/// only app/focus identity, never the field's text or selected contents.
struct VaultPasteTarget {
    let processIdentifier: pid_t
    let appName: String
    fileprivate var focus: VaultFocusSnapshot?

    init(processIdentifier: pid_t, appName: String) {
        self.processIdentifier = processIdentifier
        self.appName = appName
    }
}

fileprivate struct VaultFocusSnapshot {
    let application: NSRunningApplication
    let applicationElement: AXUIElement
    let field: AXUIElement?
    let window: AXUIElement?
}

enum VaultPasteError: LocalizedError, Equatable {
    case demoDisabled
    case accessibilityRequired
    case targetUnavailable
    case targetChanged
    case modifiersHeld
    case eventUnavailable
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .demoDisabled:
            "Pasting into other apps is disabled in Demo mode."
        case .accessibilityRequired:
            "Allow Mac Tools in System Settings → Privacy & Security → Accessibility to paste into another app. You can still copy an item and paste it yourself."
        case .targetUnavailable:
            "The original text field is unavailable. Focus a text field and open Key Vault again, or copy the item and paste it yourself."
        case .targetChanged:
            "The active app or text field changed. Nothing was pasted. Open Key Vault again from the intended field, or copy the item and paste it yourself."
        case .modifiersHeld:
            "Release the keys and try again. Nothing was pasted."
        case .eventUnavailable:
            "Mac Tools couldn’t prepare the paste action. Copy the item and paste it yourself."
        case .clipboardWriteFailed:
            "Couldn’t copy this item to the clipboard. Try again."
        }
    }
}

@MainActor
protocol VaultPasting: AnyObject {
    var isTrusted: Bool { get }
    func captureTarget() -> VaultPasteTarget?
    /// The caller must dismiss its picker before invoking this method.
    func paste(_ content: ClipboardContent, to target: VaultPasteTarget, isSensitive: Bool) async throws
    func shutdown()
}

/// Separates operating-system interactions from the destination checks. Tests can
/// exercise every failure path without accessing Accessibility or posting keys.
@MainActor
protocol VaultPasteEnvironment: AnyObject {
    var isTrusted: Bool { get }
    var ownProcessIdentifier: pid_t { get }
    var frontmostProcessIdentifier: pid_t? { get }
    var modifiersReleased: Bool { get }
    func captureTarget() -> VaultPasteTarget?
    func isTargetRunning(_ target: VaultPasteTarget) -> Bool
    func activate(_ target: VaultPasteTarget) -> Bool
    func focusMatches(_ target: VaultPasteTarget) -> Bool
    func preparePaste(to target: VaultPasteTarget) -> (@MainActor () -> Void)?
}

@MainActor
final class SystemVaultPasteService: VaultPasting {
    private let isDemo: Bool
    private let access: any ClipboardAccess
    private let environment: any VaultPasteEnvironment
    private let wait: @MainActor () async throws -> Void

    init(isDemo: Bool = AppEnvironment.isDemo, access: (any ClipboardAccess)? = nil,
         environment: (any VaultPasteEnvironment)? = nil,
         wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }) {
        self.isDemo = isDemo
        self.access = access ?? SystemClipboardAccess()
        self.environment = environment ?? SystemVaultPasteEnvironment()
        self.wait = wait
    }

    var isTrusted: Bool { !isDemo && environment.isTrusted }

    func captureTarget() -> VaultPasteTarget? {
        guard !isDemo else { return nil }
        return environment.captureTarget()
    }

    func paste(_ content: ClipboardContent, to target: VaultPasteTarget, isSensitive: Bool = false) async throws {
        guard !isDemo else { throw VaultPasteError.demoDisabled }
        try Task.checkCancellation()
        guard environment.isTrusted else { throw VaultPasteError.accessibilityRequired }
        guard environment.isTargetRunning(target) else { throw VaultPasteError.targetUnavailable }
        guard frontmostIsAllowed(target) else { throw VaultPasteError.targetChanged }
        guard let post = environment.preparePaste(to: target) else { throw VaultPasteError.eventUnavailable }

        // A nonactivating panel usually leaves the destination app frontmost. If
        // this app briefly received activation, hand it back only to that app.
        if environment.frontmostProcessIdentifier != target.processIdentifier {
            guard environment.activate(target) else { throw VaultPasteError.targetUnavailable }
        }

        // Give a dismissed panel time to relinquish keyboard focus, and do not
        // mix the user's still-held Control/Option keys into Command-V.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        for _ in 0..<30 {
            try Task.checkCancellation()
            guard environment.isTrusted else { throw VaultPasteError.accessibilityRequired }
            guard environment.isTargetRunning(target) else { throw VaultPasteError.targetUnavailable }
            guard frontmostIsAllowed(target) else { throw VaultPasteError.targetChanged }
            if ready(target) { break }
            if ContinuousClock.now >= deadline { break }
            try await wait()
        }

        try Task.checkCancellation()
        guard environment.isTrusted else { throw VaultPasteError.accessibilityRequired }
        guard environment.isTargetRunning(target) else { throw VaultPasteError.targetUnavailable }
        guard environment.modifiersReleased else { throw VaultPasteError.modifiersHeld }
        guard ready(target) else { throw VaultPasteError.targetChanged }
        let written = isSensitive ? access.writeSensitive(content) : access.write(content)
        guard written else { throw VaultPasteError.clipboardWriteFailed }
        var posted = false
        defer { if isSensitive && !posted { access.clearSensitive() } }

        // Validate again after the pasteboard write, with no suspension between
        // this check and posting. Never redirect the action to a new foreground app.
        try Task.checkCancellation()
        guard environment.isTrusted else { throw VaultPasteError.accessibilityRequired }
        guard environment.isTargetRunning(target), ready(target) else { throw VaultPasteError.targetChanged }
        post()
        posted = true
    }

    func shutdown() {
        guard !isDemo else { return }
        access.clearSensitive()
    }

    private func frontmostIsAllowed(_ target: VaultPasteTarget) -> Bool {
        let current = environment.frontmostProcessIdentifier
        return current == target.processIdentifier || current == environment.ownProcessIdentifier
    }

    private func ready(_ target: VaultPasteTarget) -> Bool {
        environment.frontmostProcessIdentifier == target.processIdentifier
            && environment.modifiersReleased && environment.focusMatches(target)
    }
}

@MainActor
private final class SystemVaultPasteEnvironment: VaultPasteEnvironment {
    var isTrusted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var ownProcessIdentifier: pid_t { ProcessInfo.processInfo.processIdentifier }
    var frontmostProcessIdentifier: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var modifiersReleased: Bool {
        let released = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        // The picker may be selected with Return. Do not insert saved content
        // while a held selection key could repeat into the destination.
        let selectionKeys: [CGKeyCode] = [9, 36, 76] // V, Return, keypad Enter.
        return released && selectionKeys.allSatisfy { !CGEventSource.keyState(.combinedSessionState, key: $0) }
    }

    func captureTarget() -> VaultPasteTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated, application.processIdentifier > 0 else { return nil }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        let focused = isTrusted ? attributeElement(element, kAXFocusedUIElementAttribute) : nil
        if let focused { AXUIElementSetMessagingTimeout(focused, 0.2) }
        let field = focused.flatMap { isTextInput($0) ? $0 : nil }
        let window = isTrusted ? attributeElement(element, kAXFocusedWindowAttribute) : nil
        var target = VaultPasteTarget(processIdentifier: application.processIdentifier,
                                     appName: application.localizedName ?? "the original app")
        target.focus = VaultFocusSnapshot(application: application, applicationElement: element,
                                          field: field, window: window)
        return target
    }

    func isTargetRunning(_ target: VaultPasteTarget) -> Bool {
        guard let application = target.focus?.application else { return false }
        // Keep the captured NSRunningApplication rather than recreating one for
        // the PID, which could later be reused by an unrelated process.
        return !application.isTerminated && application.processIdentifier == target.processIdentifier
    }

    func activate(_ target: VaultPasteTarget) -> Bool {
        guard let application = target.focus?.application, !application.isTerminated else { return false }
        NSApp.yieldActivation(to: application)
        return application.activate(options: [])
    }

    func focusMatches(_ target: VaultPasteTarget) -> Bool {
        guard let snapshot = target.focus, let field = snapshot.field,
              let currentField = attributeElement(snapshot.applicationElement, kAXFocusedUIElementAttribute),
              CFEqual(field, currentField) else { return false }
        if let window = snapshot.window {
            guard let currentWindow = attributeElement(snapshot.applicationElement, kAXFocusedWindowAttribute),
                  CFEqual(window, currentWindow) else { return false }
        }
        return true
    }

    func preparePaste(to target: VaultPasteTarget) -> (@MainActor () -> Void)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return {
            down.postToPid(target.processIdentifier)
            up.postToPid(target.processIdentifier)
        }
    }

    private func attributeElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func isTextInput(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? Bool, !enabled { return false }
        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
           let role = roleValue as? String,
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return true
        }
        // Custom editors may expose text-selection support under a custom role.
        // Inspect supported attribute names, not text values or selections.
        var attributes: CFArray?
        guard AXUIElementCopyAttributeNames(element, &attributes) == .success,
              let attributes = attributes as? [String] else { return false }
        return attributes.contains(kAXSelectedTextRangeAttribute)
    }
}
