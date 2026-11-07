import XCTest
@testable import TVPairCore

final class DiscoveryHealthTests: XCTestCase {
    func testOneFailedBrowserDoesNotReportGlobalDenialWhenAnotherFindsADevice() {
        var health = DiscoveryHealth(); health.begin()
        health.failed(.manualPairing, code: -72008)
        XCTAssertTrue(health.isScanning); XCTAssertFalse(health.offerSettings)
        health.found(.remotePairing)
        XCTAssertNil(health.message); XCTAssertFalse(health.offerSettings)
        XCTAssertEqual(health.failures[.manualPairing], -72008)
        // A later error on another service must not erase the evidence of discovery.
        health.failed(.lockdown, code: -72008)
        XCTAssertNil(health.message)
    }
    func testAllFailedBrowsersStopScanningWithoutInventingPermissionStatus() {
        var health = DiscoveryHealth(); health.begin()
        for kind in ServiceKind.browsed { health.failed(kind, code: -72008) }
        XCTAssertFalse(health.isScanning); XCTAssertTrue(health.offerSettings)
        XCTAssertTrue(health.message?.contains("do not establish a permission denial") == true)
        health.begin(); XCTAssertTrue(health.isScanning); XCTAssertNil(health.message)
    }
    func testPreviouslyObservedServiceStillDisprovesBlanketDenialAfterSearchStops() {
        var health = DiscoveryHealth(); health.begin(); health.found(.remotePairing)
        for kind in ServiceKind.browsed { health.failed(kind, code: -72008) }
        XCTAssertFalse(health.isScanning); XCTAssertNil(health.message); XCTAssertFalse(health.offerSettings)
    }
}
