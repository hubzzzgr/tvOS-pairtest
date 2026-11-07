import XCTest
@testable import TVPairCore

final class AppProcessTests: XCTestCase {
    func testNotRunningAppNeverReceivesAPauseRequest() async throws {
        let rpc = ProcessRPCFixture([.integer(0)])
        let result = try await AppProcessTest.perform(app: .tikTok, action: .pause, rpc: rpc)
        XCTAssertEqual(result, .notRunning)
        let calls = await rpc.selectors; XCTAssertEqual(calls, ["processIdentifierForBundleIdentifier:"])
    }
    func testChangedPIDIsNotActedOn() async throws {
        let rpc = ProcessRPCFixture([.integer(42), .integer(43)])
        let result = try await AppProcessTest.perform(app: .instagram, action: .pause, rpc: rpc)
        XCTAssertEqual(result, .changed)
        let calls = await rpc.selectors; XCTAssertEqual(calls.count, 2)
    }
    func testDevicePermissionErrorIsReportedInsteadOfClaimingFrozen() async throws {
        let rpc = ProcessRPCFixture([.integer(42), .integer(42), .error(13)])
        do { _ = try await AppProcessTest.perform(app: .tikTok, action: .pause, rpc: rpc); XCTFail("Device denied pause") }
        catch { XCTAssertEqual(error as? TVPairError, .developer(13)) }
    }
    func testNegativePIDCannotBeUsedAsAProcessGroup() async throws {
        let rpc = ProcessRPCFixture([.integer(-1)])
        do { _ = try await AppProcessTest.perform(app: .tikTok, action: .pause, rpc: rpc); XCTFail("Invalid process") }
        catch { XCTAssertEqual(error as? TVPairError, .malformed("Instruments process identifier")) }
        let calls = await rpc.selectors; XCTAssertEqual(calls.count, 1)
    }
    func testFalseAcknowledgementIsARejection() async throws {
        let rpc = ProcessRPCFixture([.integer(42), .integer(42), .bool(false)])
        do { _ = try await AppProcessTest.perform(app: .instagram, action: .resume, rpc: rpc); XCTFail("False acknowledgement") }
        catch { XCTAssertEqual(error as? TVPairError, .developer(-1)) }
    }
    func testCancellationBetweenLookupAndActionSendsNoPause() async throws {
        let rpc = ProcessRPCFixture([.integer(42), .integer(42)], cancelBeforeAction: true)
        let task = Task { try await AppProcessTest.perform(app: .instagram, action: .pause, rpc: rpc) }
        do { _ = try await task.value; XCTFail("Cancelled pause") } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await rpc.selectors; XCTAssertEqual(calls.count, 2)
    }
}
private actor ProcessRPCFixture: ProcessControlRPC {
    var replies: [DTXValue?]
    let cancelBeforeAction: Bool
    var selectors: [String] = []
    init(_ replies: [DTXValue?], cancelBeforeAction: Bool = false) { self.replies = replies; self.cancelBeforeAction = cancelBeforeAction }
    func invoke(_ selector: String, values: [DTXValue]) async throws -> DTXValue? {
        selectors.append(selector)
        if cancelBeforeAction && selectors.count == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        guard !replies.isEmpty else { throw TVPairError.malformed("unexpected process RPC") }
        return replies.removeFirst()
    }
}
