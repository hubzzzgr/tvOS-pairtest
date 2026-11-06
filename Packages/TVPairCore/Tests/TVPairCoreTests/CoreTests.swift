import XCTest
import CryptoKit
import Security
@testable import TVPairCore

final class CoreTests: XCTestCase {
    func testServiceParsingDoesNotTreatLockdownAsRemotePairing() {
        XCTAssertEqual(ServiceKind(bonjourType: "_remotepairing-manual-pairing._tcp"), .manualPairing)
        XCTAssertFalse(ServiceKind.lockdown.supportsPairing)
        XCTAssertNil(ServiceKind(bonjourType: "_airplay._tcp."))
    }
    func testDiscoveryAddUpdateRemove() {
        var state = DiscoveryState()
        var device = AppleTVDevice(id: "one", name: "Advertised name", service: .manualPairing)
        state.update(device); XCTAssertEqual(state.devices.count, 1)
        device.addresses = ["192.168.1.25", "fe80::1%en0"]; device.port = 1234; device.hostname = "tv.local."
        state.update(device); XCTAssertEqual(state.devices["one"]?.addresses.count, 2)
        device.addresses = ["192.168.1.26"]; state.update(device)
        XCTAssertEqual(state.devices.count, 1); XCTAssertEqual(state.devices["one"]?.addresses, ["192.168.1.26"])
        state.remove(id: "one"); XCTAssertTrue(state.devices.isEmpty)
    }
    func testEndpointValidation() throws {
        XCTAssertEqual(try ConnectionEndpoint(host: "[fe80::1%en0]", port: "1234").description, "[fe80::1%en0]:1234")
        _ = try ConnectionEndpoint(host: "2001:db8::1", port: "65535")
        _ = try ConnectionEndpoint(host: "Apple-TV.local.", port: "1")
        for host in ["https://tv.local", "tv local", "", "999.1.1.1", "fe80::1", "::invalid", "tv..local", "-tv.local"] {
            XCTAssertThrowsError(try ConnectionEndpoint(host: host, port: "1234"), host)
        }
        for port in ["0", "-1", "65536", "abc", ""] { XCTAssertThrowsError(try ConnectionEndpoint(host: "tv.local", port: port)) }
    }
    func testAuthenticationCannotBeInferredFromTCP() throws {
        var state = PairingState()
        try state.move(to: .connecting)
        XCTAssertThrowsError(try state.acceptAuthentication()); XCTAssertThrowsError(try state.acceptTunnel())
        try state.move(to: .negotiating); try state.move(to: .verifying)
        try state.acceptAuthentication(); XCTAssertFalse(state.completeSuccess)
        try state.move(to: .persisting); try state.move(to: .openingTunnel); try state.acceptTunnel()
        XCTAssertFalse(state.completeSuccess); try state.move(to: .finished); XCTAssertTrue(state.completeSuccess)
    }
    func testInvalidStateTransitionAndCancellation() throws {
        var state = PairingState(); XCTAssertThrowsError(try state.move(to: .awaitingPIN))
        try state.move(to: .cancelled); XCTAssertFalse(state.authenticated)
    }
    func testTLVFragmentationAndMalformedInput() throws {
        let data = Data((0..<700).map { UInt8($0 % 256) })
        XCTAssertEqual(try TLV8.decode(TLV8.encode([(3, data)]))[3], data)
        XCTAssertThrowsError(try TLV8.decode(Data([3, 5, 1])))
        XCTAssertThrowsError(try TLV8.decode(Data([3])))
        XCTAssertThrowsError(try TLV8.check([6: Data([4]), 7: Data([3]), 8: Data([30])], state: 4)) { error in
            XCTAssertEqual(error as? TVPairError, .rejected(3, 30))
        }
    }
    func testCryptoKitSlicesAndNonzeroBasedParserInputs() throws {
        let key = SymmetricKey(size: .bits256)
        let box = try ChaChaPoly.seal(Data(repeating: 11, count: 400), using: key)
        let ciphertext = box.ciphertext
        let encoded = TLV8.encode([(5, ciphertext)])
        XCTAssertEqual(try TLV8.decode(encoded)[5], ciphertext)
        let prefixed = Data([99,99,99]) + encoded
        XCTAssertEqual(try TLV8.decode(prefixed.dropFirst(3))[5], ciphertext)
        let sealed = try PairingCrypto.seal(Data([1,2,3]), key: Data(repeating: 1, count: 32), nonce: Data(repeating: 0, count: 12))
        XCTAssertEqual(sealed.startIndex, 0)
    }
    func testOPACKRoundTripReferencesAndBounds() throws {
        let value = OPACKValue.dictionary(["name": .string("Apple TV"), "altIRK": .data(Data(repeating: 9, count: 16)), "values": .array([.integer(500), .bool(true)])])
        XCTAssertEqual(try OPACK.decode(OPACK.encode(value)), value)
        XCTAssertEqual(try OPACK.decode(Data([0xd2, 0x41, 0x61, 0xa0])), .array([.string("a"), .string("a")]))
        XCTAssertThrowsError(try OPACK.decode(Data([0xa0])))
        XCTAssertThrowsError(try OPACK.decode(Data([0x64,255,255,255,255,255,255,255,255])))
    }
    func testKeychainErrorsRemainVisible() throws {
        try KeychainStorage.check(errSecItemNotFound, allowMissing: true)
        XCTAssertThrowsError(try KeychainStorage.check(errSecMissingEntitlement)) { XCTAssertEqual($0 as? TVPairError, .keychain(errSecMissingEntitlement)) }
        XCTAssertThrowsError(try KeychainStorage.check(errSecInteractionNotAllowed))
    }
    func testRecordInteroperableKeysAndRejectMismatchedKeys() throws {
        var record = Self.record()
        let data = try record.exportPlist(), imported = try PairingRecord.importPlist(data)
        XCTAssertEqual(imported.privateKey, record.privateKey); XCTAssertNotNil(imported.importedAt)
        XCTAssertEqual(imported.hostIdentifier, record.hostIdentifier); XCTAssertNotEqual(imported.id, record.id)
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dictionary["identifier"] as? String, record.hostIdentifier)
        XCTAssertEqual(dictionary["private_key"] as? Data, record.privateKey)
        XCTAssertEqual(dictionary["alt_irk"] as? Data, record.alternateIRK)
        record.publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(try record.validate())
        let lockdown = try PropertyListSerialization.data(fromPropertyList: ["HostID": "host", "RootPrivateKey": Data([1])], format: .xml, options: 0)
        XCTAssertThrowsError(try PairingRecord.importPlist(lockdown))
    }
    func testVaultDoesNotCommitAfterBackendFailure() async throws {
        let storage = FailingStorage(), vault = CredentialVault(storage: storage)
        _ = try await vault.load()
        do { _ = try await vault.save(Self.record()); XCTFail("Expected persistence error") }
        catch { XCTAssertEqual(error as? TVPairError, .keychain(errSecMissingEntitlement)) }
        let loaded = try await vault.load()
        XCTAssertEqual(loaded.count, 0)
    }
    func testSanitizedLogsNeverContainSecretFixtures() {
        let input = "PIN=123456 token=abc-secret private_key=super-secret\n-----BEGIN PRIVATE KEY-----\nTESTKEY\n-----END PRIVATE KEY-----\nAuthorization: Bearer credential\n\"password\": \"secret with spaces\""
        let output = LogSanitizer.sanitize(input)
        for secret in ["123456", "abc-secret", "super-secret", "TESTKEY", "credential", "secret with spaces"] { XCTAssertFalse(output.contains(secret), secret) }
        let event = DiagnosticEvent(operation: .authentication, service: .remotePairing, result: .failed, message: input)
        XCTAssertFalse(LogSanitizer.export([event]).contains("123456"))
    }
    func testXPCCodecRoundTripAndMalformedLengths() throws {
        let value = XPCValue.dictionary(["test": .array([.string("hello"), .signed(-5), .unsigned(123)]), "key": .data(Data([1,2,3])), "id": .uuid(UUID())])
        let wrapper = try XPCCodec.wrapper(value, flags: 0x101, id: 4)
        XCTAssertEqual(try XPCCodec.decodeBody(wrapper.subdata(in: 24..<wrapper.count)), value)
        XCTAssertThrowsError(try XPCCodec.decodeBody(Data([0,1,2])))
    }
    func testIPv6TCPChecksumsAndCorruption() throws {
        let source = try XCTUnwrap(IPv6TCPPacket.address("fd00::1")), target = try XCTUnwrap(IPv6TCPPacket.address("fd00::2"))
        var packet = IPv6TCPPacket.make(source: source, destination: target, sourcePort: 50000, destinationPort: 1234, sequence: 99, acknowledgement: 100, flags: 0x18, payload: Data("test".utf8))
        XCTAssertEqual(try IPv6TCPPacket.parse(packet).payload, Data("test".utf8))
        packet[packet.count - 1] ^= 1; XCTAssertThrowsError(try IPv6TCPPacket.parse(packet))
    }
    func testOperationGateHandlesCancelBeforeContinuationAndDuplicateCallback() async throws {
        let gate = OperationGate<Int>(); gate.finish(.failure(CancellationError()))
        do { let _: Int = try await withCheckedThrowingContinuation { gate.install($0); gate.finish(.success(1)) }; XCTFail("Cancellation should win") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPSKOptionsCanBeConstructedWithoutPrivateFrameworks() throws {
        let transport = TCPTransport(endpoint: try ConnectionEndpoint(host: "127.0.0.1", port: "1234"), preSharedKey: Data(repeating: 1, count: 32))
        transport.cancel()
        // Construction is not TLS negotiation evidence.
    }
    func testAdvertisementIdentityAgainstPublishedSipHashVectors() {
        let key = Data(0..<16)
        XCTAssertEqual(AdvertisementIdentity.tag(key: key, identifier: ""), Data([0xdb, 0x47, 0xdd, 0x0e, 0x0e, 0x31]))
        let message = String(bytes: Array(UInt8(0)..<UInt8(15)), encoding: .utf8)!
        XCTAssertEqual(AdvertisementIdentity.tag(key: key, identifier: message), Data([0xca, 0x61, 0x49, 0xbe, 0x45, 0xe5]))
        var record = Self.record(); record.alternateIRK = key
        let tag = AdvertisementIdentity.tag(key: key, identifier: "device").base64EncodedString()
        XCTAssertTrue(AdvertisementIdentity.matches(record: record, identifier: "device", authTag: tag))
        XCTAssertFalse(AdvertisementIdentity.matches(record: record, identifier: "different", authTag: tag))
    }
    static func record() -> PairingRecord {
        let key = Curve25519.Signing.PrivateKey()
        return PairingRecord(deviceName: "Fixture only", deviceIdentifier: "test-device", productType: "AppleTV-test", hostIdentifier: UUID().uuidString, privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation, peerPublicKey: nil, peerIdentifier: nil, alternateIRK: Data(repeating: 1, count: 16), endpoint: nil)
    }
}

private struct FailingStorage: CredentialStorage {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw TVPairError.keychain(errSecMissingEntitlement) }
    func delete() throws { throw TVPairError.keychain(errSecMissingEntitlement) }
}
