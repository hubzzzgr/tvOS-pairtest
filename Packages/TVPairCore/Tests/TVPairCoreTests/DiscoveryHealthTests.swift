import XCTest
@testable import TVPairCore

final class DiscoveryHealthTests: XCTestCase {
    func testOneFailedBrowserDoesNotReportGlobalDenialWhenAnotherFindsADevice() {
        var health = DiscoveryHealth(); health.begin()
        health.failed(.manualPairing, code: -72008)
        XCTAssertTrue(health.isScanning); XCTAssertFalse(health.offerSettings)
        health.found(.remotePairing)
        XCTAssertTrue(health.message?.contains("Missing Bonjour configuration") == true); XCTAssertFalse(health.offerSettings)
        XCTAssertEqual(health.failures[.manualPairing], -72008)
        // A later error on another service must not erase the evidence of discovery.
        health.failed(.lockdown, code: -72008)
        XCTAssertTrue(health.message?.contains(ServiceKind.manualPairing.rawValue) == true)
    }
    func testAllFailedBrowsersStopScanningWithoutInventingPermissionStatus() {
        var health = DiscoveryHealth(); health.begin()
        for kind in ServiceKind.browsed { health.failed(kind, code: -72008) }
        XCTAssertFalse(health.isScanning); XCTAssertFalse(health.offerSettings)
        XCTAssertTrue(health.message?.contains("Missing Bonjour configuration") == true)
        health.begin(); XCTAssertTrue(health.isScanning); XCTAssertNil(health.message)
    }
    func testPreviouslyObservedServiceStillDisprovesBlanketDenialAfterSearchStops() {
        var health = DiscoveryHealth(); health.begin(); health.found(.remotePairing)
        for kind in ServiceKind.browsed { health.failed(kind, code: -72008) }
        XCTAssertFalse(health.isScanning); XCTAssertTrue(health.message?.contains("Other services can still appear") == true); XCTAssertFalse(health.offerSettings)
    }
}
