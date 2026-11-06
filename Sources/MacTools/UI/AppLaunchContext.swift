import AppKit
import CoreServices

/// Launch intent is separate from the persisted login-item registration.
/// Being registered must never make a manual launch behave like a login launch.
enum AppLaunchContext {
    static func requestedBackground(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> Bool {
        arguments.contains("--background") || infoDictionary["MacToolsBackgroundLaunch"] as? Bool == true
    }

    static func isLoginItemEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return isLoginItemEvent(
            eventClass: event.eventClass,
            eventID: event.eventID,
            launchReason: event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        )
    }

    static func isLoginItemEvent(
        eventClass: AEEventClass,
        eventID: AEEventID,
        launchReason: AEKeyword?
    ) -> Bool {
        eventClass == kCoreEventClass && eventID == kAEOpenApplication && launchReason == keyAELaunchedAsLogInItem
    }
}
