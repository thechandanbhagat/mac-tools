import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
private final class SystemLoginItemService: LoginItemService {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
private final class DemoLoginItemService: LoginItemService {
    var status: LaunchAtLoginStatus = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSettings() {}
}

/// macOS owns this setting. Never infer a successful registration from a saved preference.
@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    /// A pending registration remains checked so the user can cancel it.
    /// The accompanying approval message makes clear that it cannot launch yet.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }
    var statusMessage: String? {
        switch status {
        case .requiresApproval:
            "Mac Tools won’t launch at login until you allow it in Login Items."
        case .notFound:
            "Launch at login is unavailable. Open the installed Mac Tools app and try again."
        case .enabled, .notRegistered:
            nil
        }
    }

    init(isDemo: Bool = false, service: (any LoginItemService)? = nil) {
        // Demo mode must never read or alter the host's login-item registration.
        let selectedService: any LoginItemService = isDemo
            ? DemoLoginItemService()
            : (service ?? SystemLoginItemService())
        self.service = selectedService
        status = selectedService.status
    }

    func refresh() {
        let currentStatus = service.status
        if currentStatus != status {
            status = currentStatus
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != isEnabled else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            status = service.status
            if enabled != isEnabled {
                errorMessage = enabled
                    ? "macOS did not enable launch at login. Try again."
                    : "macOS did not turn off launch at login. Try again."
            }
        } catch {
            // An operation can change the system status even when it reports an error.
            status = service.status
            errorMessage = "Couldn’t \(enabled ? "enable" : "turn off") launch at login. \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() { service.openSettings() }
}
