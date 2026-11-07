import XCTest
@testable import TVPairCore

final class InstrumentsTests: XCTestCase {
    // Literal auxiliary fixtures: these do not use the production encoder.
    private let integerArgument = Data([10,0,0,0, 3,0,0,0, 42,0,0,0])
    private func decodeAux(_ aux: Data) throws -> [DTXValue] {
        let payload = InstrumentsPeer.uint(2) + InstrumentsPeer.uint(UInt64(aux.count)) + InstrumentsPeer.uint(UInt64(aux.count), count: 8) + aux
        return try DTXCodec.decodePayload(payload, id: 1, conversation: 0, channel: 0, expectsReply: false).arguments
    }
    func testAuxiliaryDictionaryAcceptsFlagVariants() throws {
        for marker: UInt8 in [0, 1, 2, 7] {
            let header = Data([0xf0,marker,0,0, 0,0,0,0, 12,0,0,0,0,0,0,0])
            XCTAssertEqual(try decodeAux(header + integerArgument), [.integer(42)])
        }
    }
    func testLegacyAuxiliaryCapacityIsNotAMagicNumber() throws {
        let header = Data([0,4,0,0, 0,0,0,0, 12,0,0,0,0,0,0,0]) // Capacity hint 1024.
        XCTAssertEqual(try decodeAux(header + integerArgument), [.integer(42)])
        let bare = Data([3,0,0,0, 42,0,0,0])
        let bareHeader = Data([0,4,0,0, 0,0,0,0, 8,0,0,0,0,0,0,0])
        XCTAssertEqual(try decodeAux(bareHeader + bare), [.integer(42)])
    }
    func testNestedDictionaryInLegacyAuxiliaryEnvelope() throws {
        let outer = Data([0,4,0,0, 0,0,0,0, 28,0,0,0,0,0,0,0])
        let nested = Data([0xf0,2,0,0, 0,0,0,0, 12,0,0,0,0,0,0,0])
        XCTAssertEqual(try decodeAux(outer + nested + integerArgument), [.integer(42)])
    }
    func testEmptyAndNullAuxiliaryValues() throws {
        let empty = Data([0xf0,7,0,0, 0,0,0,0, 0,0,0,0,0,0,0,0])
        XCTAssertEqual(try decodeAux(empty), [])
        let header = Data([0xf0,7,0,0, 0,0,0,0, 12,0,0,0,0,0,0,0])
        XCTAssertEqual(try decodeAux(header + Data([10,0,0,0, 2,0,0,0, 0,0,0,0])), [.null])
        let nullHeader = Data([0xf0,7,0,0, 0,0,0,0, 8,0,0,0,0,0,0,0])
        XCTAssertEqual(try decodeAux(nullHeader + Data([10,0,0,0, 10,0,0,0])), [.null])
    }
    func testAuxiliaryLengthKeyAndValueBoundariesAreStillEnforced() throws {
        let header = Data([0xf0,7,0,0, 0,0,0,0, 12,0,0,0,0,0,0,0])
        XCTAssertThrowsError(try decodeAux(header))
        XCTAssertThrowsError(try decodeAux(header + integerArgument + Data([0])))
        XCTAssertThrowsError(try decodeAux(Data([0xf0,7])))
        XCTAssertThrowsError(try decodeAux(header + Data([3,0,0,0, 3,0,0,0, 42,0,0,0])))
        XCTAssertThrowsError(try decodeAux(header + Data([10,0,0,0, 2,0,0,0, 1,0,0,0])))
        let missingValue = Data([0xf0,7,0,0, 0,0,0,0, 4,0,0,0,0,0,0,0, 10,0,0,0])
        XCTAssertThrowsError(try decodeAux(missingValue))
        let oversizedNested = Data([0,4,0,0, 0,0,0,0, 16,0,0,0,0,0,0,0, 0xf0,2,0,0, 0,0,0,0, 255,255,255,255,255,255,255,255])
        XCTAssertThrowsError(try decodeAux(oversizedNested))
    }
    func testAuxiliaryArgumentAndNestingLimits() throws {
        var entries = Data()
        for _ in 0..<65 { entries += integerArgument }
        let header = Data([0xf0,7,0,0, 0,0,0,0]) + InstrumentsPeer.uint(UInt64(entries.count), count: 8)
        XCTAssertThrowsError(try decodeAux(header + entries))
        var nested = integerArgument
        for _ in 0..<9 {
            nested = Data([0xf0,7,0,0, 0,0,0,0]) + InstrumentsPeer.uint(UInt64(nested.count), count: 8) + nested
            nested = Data([10,0,0,0]) + nested
        }
        let outer = Data([0xf0,7,0,0, 0,0,0,0]) + InstrumentsPeer.uint(UInt64(nested.count), count: 8)
        XCTAssertThrowsError(try decodeAux(outer + nested))
    }
    func testHubHandshakeReadOnlyProbeAndScopedPauseResumeRPCs() async throws {
        let wire = try InstrumentsPeerTransport(fragmented: true)
        let client = InstrumentsTransport(stream: wire)
        try await client.open()
        let info = try await client.channel("com.apple.instruments.server.services.deviceinfo")
        let list = try await client.call(channel: info, selector: "runningProcesses")
        XCTAssertEqual(list, .array([]))
        let process = try await client.channel("com.apple.instruments.server.services.processcontrol")
        let rpc = InstrumentsProcessRPC(transport: client, channel: process)
        let paused = try await AppProcessTest.perform(app: .tikTok, action: .pause, rpc: rpc)
        let resumed = try await AppProcessTest.perform(app: .instagram, action: .resume, rpc: rpc)
        XCTAssertEqual(paused, .acknowledged(pid: 512)); XCTAssertEqual(resumed, .acknowledged(pid: 512))
        let actions = await wire.peer.actions
        XCTAssertEqual(actions, ["suspendPid:", "resumePid:"])
        let bundles = await wire.peer.bundles
        XCTAssertEqual(bundles, ["com.zhiliaoapp.musically", "com.zhiliaoapp.musically", "com.burbn.instagram", "com.burbn.instagram"])
    }
    func testRejectedInstrumentsChannelDoesNotBecomeAvailable() async throws {
        let wire = try InstrumentsPeerTransport(denyChannel: true), client = InstrumentsTransport(stream: wire)
        try await client.open()
        do { _ = try await client.channel("com.apple.instruments.server.services.deviceinfo"); XCTFail("Denied channel") }
        catch { XCTAssertEqual(error as? TVPairError, .developer(13)) }
    }
    func testMismatchedFragmentIdentityFailsClosed() async throws {
        let wire = try InstrumentsPeerTransport(fragmented: true, corruptFragment: true), client = InstrumentsTransport(stream: wire)
        try await client.open()
        let channel = try await client.channel("com.apple.instruments.server.services.deviceinfo")
        do { _ = try await client.call(channel: channel, selector: "runningProcesses"); XCTFail("Mismatched fragment") }
        catch { XCTAssertEqual(error as? TVPairError, .malformed("Instruments fragment identity")) }
    }
    func testOversizedHeaderIsRejectedBeforePayloadRead() async throws {
        var header = Data([0x79,0x5b,0x3d,0x1f,32,0,0,0,0,0,1,0])
        header += Data([1,0,16,0]) // 1 MiB + 1, followed by an otherwise empty header.
        header += Data(repeating: 0, count: 16)
        do { _ = try await DTXCodec.receive(from: ScriptedTransport(bytes: header), deadline: Date().addingTimeInterval(1)); XCTFail("Oversized frame") }
        catch { XCTAssertEqual(error as? TVPairError, .malformed("Instruments message header")) }
    }
    func testNativeArchiveInteroperabilityAndNSErrorCodeOnly() throws {
        let object: NSDictionary = ["name": "Synthetic", "pid": NSNumber(value: Int64(512)), "isApplication": true]
        let bytes = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        let decoded = try DTXValue.unarchive(bytes).dictionary
        XCTAssertEqual(decoded?["pid"], .integer(512)); XCTAssertEqual(decoded?["isApplication"], .bool(true))
        let error = NSError(domain: "SyntheticDomain", code: 13, userInfo: [NSLocalizedDescriptionKey: "do not expose this peer description"])
        XCTAssertEqual(try DTXValue.unarchive(NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: false)), .error(13))
        let encoded = try DTXValue.string("suspendPid:").archived()
        XCTAssertEqual(try NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: encoded) as String?, "suspendPid:")
    }
    func testUnknownArchiveClassesAndMalformedBytesAreRejected() throws {
        let set = try NSKeyedArchiver.archivedData(withRootObject: NSSet(array: ["unexpected"]), requiringSecureCoding: false)
        XCTAssertThrowsError(try DTXValue.unarchive(set))
        XCTAssertThrowsError(try DTXValue.unarchive(Data("not an archive".utf8)))
    }
    func testRSDNameUsesLabelledRecordFallbackWithoutInventingValues() {
        let properties: [String: XPCValue] = ["ProductType": .string("iPhone-test"), "OSVersion": .string("27.0.1")]
        let hub: [String: XPCValue] = ["com.apple.instruments.dtservicehub": .dictionary(["Port": .string("54321")])]
        let info = DeviceInformation.fromRSD(properties: properties, services: hub, savedName: "Paired phone")
        XCTAssertEqual(info.name, "Paired phone"); XCTAssertEqual(info.nameSource, "Saved pairing record")
        XCTAssertEqual(info.developerServices, ["com.apple.instruments.dtservicehub"])
        XCTAssertFalse(info.instrumentsServiceResponded, "Advertisement alone must not pass the probe")
        XCTAssertNil(DeviceInformation.fromRSD(properties: properties, services: hub, savedName: "Unavailable").name)
        let actual = DeviceInformation.fromRSD(properties: ["DeviceName": .string("Current RSD name")], services: hub, savedName: "Old record name")
        XCTAssertEqual(actual.name, "Current RSD name"); XCTAssertEqual(actual.nameSource, "RSD properties")
        XCTAssertEqual(DeveloperConnection.port(hub["com.apple.instruments.dtservicehub"]), 54321)
        XCTAssertNil(DeveloperConnection.port(.dictionary(["Port": .unsigned(65536)])))
    }
}

private final class InstrumentsPeerTransport: ByteTransport, @unchecked Sendable {
    let peer: InstrumentsPeer
    init(fragmented: Bool = false, denyChannel: Bool = false, corruptFragment: Bool = false) throws { peer = try InstrumentsPeer(fragmented: fragmented, denyChannel: denyChannel, corruptFragment: corruptFragment) }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ bytes: Data, timeout: TimeInterval) async throws { try await peer.handle(bytes) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}

/// Independent peer framing using Foundation archives and literal DTX headers,
/// rather than the production codec's encoder or decoder.
private actor InstrumentsPeer {
    let fragmented: Bool, denyChannel: Bool, corruptFragment: Bool
    var output = Data(), actions: [String] = [], bundles: [String] = []
    init(fragmented: Bool, denyChannel: Bool, corruptFragment: Bool) throws {
        self.fragmented = fragmented; self.denyChannel = denyChannel; self.corruptFragment = corruptFragment
        let capability: NSDictionary = ["com.apple.private.DTXConnection": 1]
        let payload = try Self.payload(type: 2, value: "_notifyOfPublishedCapabilities:" as NSString, args: [capability])
        output = Self.header(id: 100, channel: 0, conversation: 0, size: payload.count) + payload
    }
    static func uint(_ value: UInt64, count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
    static func number(_ data: Data, _ position: Int, _ count: Int = 4) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(data[position + $1]) << (8 * $1) } }
    static func header(id: UInt32, channel: UInt32, conversation: UInt32, size: Int, fragment: UInt16 = 0, count: UInt16 = 1) -> Data {
        var header = Data([0x79,0x5b,0x3d,0x1f,32,0,0,0])
        header += uint(UInt64(fragment), count: 2) + uint(UInt64(count), count: 2) + uint(UInt64(size))
        header += uint(UInt64(id)) + uint(UInt64(conversation)) + uint(UInt64(channel)) + uint(0)
        return header
    }
    static func payload(type: UInt32, value: Any?, args: [Any] = []) throws -> Data {
        var aux = Data()
        for arg in args {
            let archived = try NSKeyedArchiver.archivedData(withRootObject: arg, requiringSecureCoding: false)
            aux += uint(10) + uint(2) + uint(UInt64(archived.count)) + archived
        }
        // Exercise a peer flag variant, rather than echoing the client's 0x1F0.
        if !aux.isEmpty { aux = uint(0x7f0) + uint(0) + uint(UInt64(aux.count), count: 8) + aux }
        let object = try value.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: false) } ?? Data()
        return uint(UInt64(type)) + uint(UInt64(aux.count)) + uint(UInt64(aux.count + object.count), count: 8) + aux + object
    }
    func take(_ count: Int) throws -> Data {
        guard count <= output.count else { throw TVPairError.closed }
        let bytes = output.prefix(count).zeroBased; output.removeFirst(count); return bytes
    }
    func handle(_ bytes: Data) throws {
        let h = bytes.zeroBased, body = h.dropFirst(32).zeroBased
        guard Self.number(h, 0) == 0x1f3d5b79 else { throw TVPairError.malformed("synthetic DTX magic") }
        if Self.number(h, 20) != 0 { return }
        let aux = Int(Self.number(body, 4)), id = UInt32(Self.number(h, 16)), channel = UInt32(Self.number(h, 24))
        let archive = body.dropFirst(16 + aux).zeroBased
        guard let selector = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: archive) as String? else { throw TVPairError.malformed("synthetic DTX selector") }
        var args: [Any] = [], p = 32
        while aux > 0 && p < 16 + aux {
            guard Self.number(body, p) == 10 else { throw TVPairError.malformed("synthetic DTX separator") }; p += 4
            let kind = Self.number(body, p); p += 4
            if kind == 3 { args.append(NSNumber(value: Self.number(body, p))); p += 4 }
            else {
                guard kind == 2 else { throw TVPairError.malformed("synthetic DTX argument") }
                let size = Int(Self.number(body, p)); p += 4
                let value = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSString.self, NSNumber.self, NSDictionary.self], from: body.subdata(in: p..<p + size))
                p += size; if let value { args.append(value) }
            }
        }
        if selector == "_notifyOfPublishedCapabilities:" { return }
        let response: Any?, type: UInt32
        switch selector {
        case "_requestChannelWithCode:identifier:":
            response = denyChannel ? NSError(domain: "Synthetic", code: 13) : nil; type = denyChannel ? 4 : 0
        case "runningProcesses": response = NSArray(); type = 3
        case "processIdentifierForBundleIdentifier:":
            guard let bundle = args.first as? String, ProcessTestApp.allCases.contains(where: { $0.bundleIdentifier == bundle }) else { throw TVPairError.malformed("unscoped bundle request") }
            bundles.append(bundle); response = NSNumber(value: Int64(512)); type = 3
        case "suspendPid:", "resumePid:":
            guard (args.first as? NSNumber)?.intValue == 512 else { throw TVPairError.malformed("unresolved PID request") }
            actions.append(selector); response = nil; type = 0
        default: throw TVPairError.malformed("unexpected synthetic DTX method")
        }
        let payload = try Self.payload(type: type, value: response)
        if selector == "runningProcesses" && fragmented {
            output += Self.header(id: id, channel: channel, conversation: 1, size: payload.count, fragment: 0, count: 3)
            output += Self.header(id: id, channel: channel, conversation: 1, size: 20, fragment: 1, count: 3) + payload.prefix(20)
            output += Self.header(id: corruptFragment ? id + 1 : id, channel: channel, conversation: 1, size: payload.count - 20, fragment: 2, count: 3) + payload.dropFirst(20)
        } else { output += Self.header(id: id, channel: channel, conversation: 1, size: payload.count) + payload }
    }
}
