import Foundation
import XCTest
@testable import MacTools

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testInitialStateComesFromSystemRatherThanRegistering() {
        for status in [LaunchAtLoginStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = FakeLoginItemService(status: status)
            let model = LaunchAtLoginModel(service: service)

            XCTAssertEqual(model.status, status)
            XCTAssertEqual(model.isEnabled, status == .enabled || status == .requiresApproval)
            XCTAssertEqual(model.requiresApproval, status == .requiresApproval)
            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.unregisterCount, 0)
        }
    }

    func testEnablingAndDisablingUseSystemService() {
        let service = FakeLoginItemService()
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertNil(model.errorMessage)

        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testPendingApprovalIsVisibleAndCanBeCancelled() {
        let service = FakeLoginItemService()
        service.registrationResult = .requiresApproval
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.requiresApproval)
        XCTAssertNotNil(model.statusMessage)
        XCTAssertNil(model.errorMessage)

        model.openLoginItemsSettings()
        XCTAssertEqual(service.openSettingsCount, 1)

        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.requiresApproval)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testRegistrationFailureDoesNotClaimEnabled() {
        let service = FakeLoginItemService()
        service.registrationError = TestError.denied
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.status, .notRegistered)
        XCTAssertTrue(model.errorMessage?.contains("Test denial") == true)
    }

    func testUnregistrationFailureRetainsActualEnabledState() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregistrationError = TestError.denied
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(false)

        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.errorMessage?.contains("turn off") == true)
    }

    func testReportedSuccessDoesNotReplaceActualStatus() {
        let service = FakeLoginItemService()
        service.registrationResult = .notRegistered
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertFalse(model.isEnabled)
        XCTAssertNotNil(model.errorMessage)
    }

    func testStatusIsRereadEvenWhenRegistrationThrows() {
        let service = FakeLoginItemService()
        service.registrationError = TestError.denied
        service.statusBeforeRegistrationError = .requiresApproval
        let model = LaunchAtLoginModel(service: service)

        model.setEnabled(true)

        XCTAssertTrue(model.requiresApproval)
        XCTAssertNotNil(model.statusMessage)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRefreshReflectsChangesMadeInSystemSettings() {
        let service = FakeLoginItemService(status: .enabled)
        let model = LaunchAtLoginModel(service: service)

        service.status = .requiresApproval
        model.refresh()
        XCTAssertTrue(model.requiresApproval)

        service.status = .notRegistered
        model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.statusMessage)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    func testRepeatedRequestsAndStaleUIAvoidDuplicateOperations() {
        let service = FakeLoginItemService()
        let model = LaunchAtLoginModel(service: service)

        service.status = .enabled
        model.setEnabled(true)
        XCTAssertEqual(service.registerCount, 0)

        model.setEnabled(false)
        model.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    func testMissingServiceHasVisibleExplanation() {
        let model = LaunchAtLoginModel(service: FakeLoginItemService(status: .notFound))

        XCTAssertFalse(model.isEnabled)
        XCTAssertNotNil(model.statusMessage)
    }

    func testDemoNeverTouchesInjectedHostService() {
        let service = FakeLoginItemService(status: .enabled)
        let model = LaunchAtLoginModel(isDemo: true, service: service)

        XCTAssertFalse(model.isEnabled)
        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        model.refresh()
        model.openLoginItemsSettings()
        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)

        XCTAssertEqual(service.statusReadCount, 0)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
        XCTAssertEqual(service.openSettingsCount, 0)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    private var storedStatus: LaunchAtLoginStatus
    private(set) var statusReadCount = 0
    var status: LaunchAtLoginStatus {
        get { statusReadCount += 1; return storedStatus }
        set { storedStatus = newValue }
    }
    var registrationResult: LaunchAtLoginStatus = .enabled
    var registrationError: Error?
    var statusBeforeRegistrationError: LaunchAtLoginStatus?
    var unregistrationError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSettingsCount = 0

    init(status: LaunchAtLoginStatus = .notRegistered) { storedStatus = status }

    func register() throws {
        registerCount += 1
        if let registrationError {
            if let statusBeforeRegistrationError { status = statusBeforeRegistrationError }
            throw registrationError
        }
        status = registrationResult
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func openSettings() { openSettingsCount += 1 }
}

private enum TestError: LocalizedError {
    case denied
    var errorDescription: String? { "Test denial" }
}
