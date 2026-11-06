import AppKit
import CoreServices
import XCTest
@testable import MacTools

final class AppLaunchContextTests: XCTestCase {
    func testOrdinaryLaunchDoesNotRequestBackground() {
        XCTAssertFalse(AppLaunchContext.requestedBackground(arguments: ["MacTools"], infoDictionary: [:]))
    }

    func testExplicitBackgroundArgumentWorksWithoutLoginRegistration() {
        XCTAssertTrue(AppLaunchContext.requestedBackground(arguments: ["MacTools", "--background"], infoDictionary: [:]))
        XCTAssertFalse(AppLaunchContext.requestedBackground(arguments: ["MacTools", "--background=false"], infoDictionary: [:]))
    }

    func testPreviewBundleCanRequestBackgroundLaunch() {
        XCTAssertTrue(AppLaunchContext.requestedBackground(arguments: [], infoDictionary: ["MacToolsBackgroundLaunch": true]))
        XCTAssertFalse(AppLaunchContext.requestedBackground(arguments: [], infoDictionary: ["MacToolsBackgroundLaunch": false]))
    }

    func testMissingAppleEventIsAnOrdinaryLaunch() {
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(nil))
    }

    func testLoginItemOpenEventRequestsBackground() {
        XCTAssertTrue(AppLaunchContext.isLoginItemEvent(eventClass: kCoreEventClass,
                                                      eventID: kAEOpenApplication,
                                                      launchReason: keyAELaunchedAsLogInItem))
    }

    func testReopenAndUnrelatedEventsAreNotLoginLaunches() {
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(eventClass: kCoreEventClass,
                                                       eventID: kAEReopenApplication,
                                                       launchReason: keyAELaunchedAsLogInItem))
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(eventClass: AEEventClass(0),
                                                       eventID: kAEOpenApplication,
                                                       launchReason: keyAELaunchedAsLogInItem))
    }

    func testOrdinaryOpenAndServiceEventsAreNotLoginLaunches() {
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(eventClass: kCoreEventClass,
                                                       eventID: kAEOpenApplication,
                                                       launchReason: nil))
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(eventClass: kCoreEventClass,
                                                       eventID: kAEOpenApplication,
                                                       launchReason: keyAELaunchedAsServiceItem))
    }

    func testDescriptorReadsTheLaunchReasonParameter() {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass,
                                                    eventID: kAEOpenApplication,
                                                    targetDescriptor: nil,
                                                    returnID: AEReturnID(kAutoGenerateReturnID),
                                                    transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(AppLaunchContext.isLoginItemEvent(event))

        event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsServiceItem), forKeyword: keyAEPropData)
        XCTAssertFalse(AppLaunchContext.isLoginItemEvent(event))
    }
}
