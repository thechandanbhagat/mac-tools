import Carbon
import Foundation

/// Carbon registers only this combination; it does not monitor ordinary keystrokes.
@MainActor
final class VaultGlobalShortcut {
    nonisolated static let displayName = "⌃⌥V"

    enum RegistrationError: LocalizedError {
        case handler(OSStatus)
        case shortcut(OSStatus)

        var errorDescription: String? {
            switch self {
            case .shortcut(let status) where status == OSStatus(eventHotKeyExistsErr):
                "Control–Option–V is already used by another app. Disable its shortcut, then try again."
            case .shortcut(let status):
                "Couldn’t register Control–Option–V (error \(status)). Try enabling the shortcut again."
            case .handler(let status):
                "Couldn’t listen for the Key Vault shortcut (error \(status)). Try enabling it again."
            }
        }
    }

    private var registration: Registration?
    var isRegistered: Bool { registration != nil }

    /// Repeated setup replaces the action without registering the same hotkey twice.
    func register(action: @escaping @MainActor () -> Void) throws {
        if let registration {
            registration.callback.action = action
            return
        }

        let callback = Callback(action: action)
        let context = Unmanaged.passRetained(callback).toOpaque()
        var handler: EventHandlerRef?
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { call, event, context in
            VaultGlobalShortcut.handleEvent(call, event, context)
        },
                                                1, &event, context, &handler)
        guard handlerStatus == noErr, let handler else {
            if let handler { RemoveEventHandler(handler) }
            Unmanaged<Callback>.fromOpaque(context).release()
            throw RegistrationError.handler(handlerStatus)
        }

        var hotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey),
                                               Self.identifier, GetApplicationEventTarget(),
                                               OptionBits(kEventHotKeyExclusive), &hotKey)
        guard hotKeyStatus == noErr, let hotKey else {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            RemoveEventHandler(handler)
            Unmanaged<Callback>.fromOpaque(context).release()
            throw RegistrationError.shortcut(hotKeyStatus)
        }

        registration = Registration(handler: handler, hotKey: hotKey, context: context)
    }

    func unregister() {
        registration?.dispose()
        registration = nil
    }

    deinit {
        // A global-actor object can lose its last reference away from its actor.
        // The retained callback survives until Carbon has removed its handler.
        guard let registration else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { registration.dispose() }
        } else {
            Task { @MainActor in registration.dispose() }
        }
    }

    private static var identifier: EventHotKeyID {
        EventHotKeyID(signature: OSType(0x4D54564B), id: 1) // MTVK
    }

    private nonisolated static func handleEvent(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                                 _ context: UnsafeMutableRawPointer?) -> OSStatus {
        guard let event, let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr else { return status }
        let callback = Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue()
        return MainActor.assumeIsolated {
            guard identifier.signature == Self.identifier.signature, identifier.id == Self.identifier.id else {
                return OSStatus(eventNotHandledErr)
            }
            // Application event-target handlers run on the main event loop.
            guard let action = callback.action else { return OSStatus(eventNotHandledErr) }
            action()
            return noErr
        }
    }

    @MainActor
    private final class Callback {
        var action: (@MainActor () -> Void)?
        init(action: @escaping @MainActor () -> Void) { self.action = action }
    }

    /// Immutable handles are transferred to the main actor only for destruction.
    private struct Registration: @unchecked Sendable {
        let handler: EventHandlerRef
        let hotKey: EventHotKeyRef
        let context: UnsafeMutableRawPointer

        @MainActor var callback: Callback { Unmanaged<Callback>.fromOpaque(context).takeUnretainedValue() }

        @MainActor func dispose() {
            callback.action = nil
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(handler)
            Unmanaged<Callback>.fromOpaque(context).release()
        }
    }
}
