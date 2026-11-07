import XCTest
import CryptoKit
@testable import TVPairCore

final class PairableHostTests: XCTestCase {
    func testDeviceInitiatedSetupVerifiesBothIdentities() async throws {
        let transport = try OnboardingTransport(), identity = try PairableHostIdentity()
        let host = PairableHostSession(transport: transport, identity: identity)
        let record = try await host.accept(displayPIN: { pin in if let pin { await transport.enterCode(pin) } }, report: { _,_,_,_ in })
        let peerKey = await transport.peerPublicKey()
        XCTAssertEqual(record.peerPublicKey, peerKey); XCTAssertEqual(record.hostIdentifier, identity.identifier)
        XCTAssertEqual(record.deviceName, "Synthetic iPhone"); XCTAssertEqual(record.productType, "iPhone-test")
        let verified = await transport.verifiedHost()
        XCTAssertTrue(verified); try record.validate()
    }
    func testWrongClientProofCannotCreateARecord() async throws {
        let transport = try OnboardingTransport(tamper: .proof), host = PairableHostSession(transport: transport, identity: try PairableHostIdentity())
        do {
            _ = try await host.accept(displayPIN: { pin in if let pin { await transport.enterCode(pin) } }, report: { _,_,_,_ in })
            XCTFail("Bad proof must not authenticate")
        } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
        let verified = await transport.verifiedHost(); XCTAssertFalse(verified)
    }
    func testWrongDeviceSignatureCannotCreateARecord() async throws {
        let transport = try OnboardingTransport(tamper: .signature), host = PairableHostSession(transport: transport, identity: try PairableHostIdentity())
        do {
            _ = try await host.accept(displayPIN: { pin in if let pin { await transport.enterCode(pin) } }, report: { _,_,_,_ in })
            XCTFail("Bad peer identity must not authenticate")
        } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
        let verified = await transport.verifiedHost(); XCTAssertFalse(verified)
    }
    func testRegularEndpointDoesNotBootstrapNewTrust() async throws {
        let transport = ScriptedTransport(bytes: Data()), client = RemotePairingClient(transport: ScriptedTransport(bytes: Data()))
        let actual = RemotePairingClient(transport: transport)
        do {
            _ = try await actual.authenticate(endpoint: ConnectionEndpoint(host: "iphone.local", port: "49152"), service: .remotePairing, requestPIN: { XCTFail("Must not request a TV code"); return "123456" }, report: { _,_,_,_ in })
            XCTFail("Trusted endpoint is not a new-pairing entry point")
        } catch { guard case .some(.unsupported(_)) = error as? TVPairError else { return XCTFail("Expected an explicit unsupported-flow error") } }
        XCTAssertTrue(transport.writes.isEmpty)
        do { _ = try await client.createTunnelListener(); XCTFail("Unpaired client cannot create a tunnel") } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
    }
    func testVersionRangeIncludesTheRequestedVersionRatherThanRequiringEqualMaxima() throws {
        try PairingWireVersion.validatePeer(maximum: 26, minimum: 8)
        XCTAssertThrowsError(try PairingWireVersion.validatePeer(maximum: 26, minimum: 20))
        XCTAssertThrowsError(try PairingWireVersion.validatePeer(maximum: 18, minimum: 8))
        XCTAssertThrowsError(try PairingWireVersion.validatePeer(maximum: 19, minimum: 26))
    }
}

private final class OnboardingTransport: ByteTransport, @unchecked Sendable {
    let peer: OnboardingPeer
    init(tamper: OnboardingPeer.Tamper = .none) throws { peer = try OnboardingPeer(tamper: tamper) }
    func enterCode(_ code: String) async { await peer.enterCode(code) }
    func peerPublicKey() async -> Data { await peer.signing.publicKey.rawRepresentation }
    func verifiedHost() async -> Bool { await peer.hostVerified }
    func connect(timeout: TimeInterval) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: TimeInterval) async throws { try await peer.respond(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}
private actor OnboardingPeer {
    enum Tamper: Equatable { case none, proof, signature }
    let tamper: Tamper
    let signing = Curve25519.Signing.PrivateKey()
    let identifier = Data("synthetic-phone-account".utf8)
    var code: String?
    var srp: SRPSession?
    var hostVerified = false
    var output: Data
    init(tamper: Tamper) throws {
        self.tamper = tamper
        output = try FramedJSON.encode(["originatedBy": "host", "sequenceNumber": 0, "message": ["plain": ["_0": ["request": ["_0": ["handshake": ["_0": ["wireProtocolVersion": 26, "hostOptions": ["attemptPairVerify": false]]]]]]]]])
    }
    func enterCode(_ value: String) { code = value }
    func take(_ count: Int) throws -> Data {
        guard output.count >= count else { throw TVPairError.closed }
        let data = output.prefix(count).zeroBased; output.removeFirst(count); return data
    }
    func enqueue(_ entries: [(UInt8, Data)]) throws {
        output += try FramedJSON.encode(["originatedBy": "host", "sequenceNumber": 1, "message": ["plain": ["_0": ["event": ["_0": ["pairingData": ["_0": ["kind": "setupManualPairing", "startNewSession": false, "data": TLV8.encode(entries).base64EncodedString()]]]]]]]])
    }
    func respond(_ frame: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: frame.dropFirst(11)) as? [String: Any], object["originatedBy"] as? String == "device", let plain = nested(object, "message", "plain", "_0") as? [String: Any] else { throw TVPairError.malformed("synthetic onboarding envelope") }
        if let version = nested(plain, "response", "_1", "handshake", "_0", "wireProtocolVersion") as? Int {
            guard version == 26, nested(plain, "response", "_1", "handshake", "_0", "deviceOptions", "allowsPinlessPairing") as? Bool == false else { throw TVPairError.malformed("synthetic handshake options") }
            try enqueue([(0, Data([0])), (6, Data([1]))]); return
        }
        guard let encoded = nested(plain, "event", "_0", "pairingData", "_0", "data") as? String, let bytes = Data(base64Encoded: encoded) else { throw TVPairError.malformed("synthetic onboarding TLV") }
        let values = try TLV8.decode(bytes)
        switch values[6]?.first {
        case 2:
            guard let code else { throw TVPairError.authentication }
            let session = try SRPSession(pin: code, serverPublic: TLV8.require(values, 3), salt: TLV8.require(values, 2))
            srp = session; var proof = session.proof
            if tamper == .proof { proof[0] ^= 1 }
            try enqueue([(6, Data([3])), (3, session.publicKey), (4, proof)])
        case 4:
            if values[7] != nil { return }
            guard let srp, srp.verify(try TLV8.require(values, 4)) else { throw TVPairError.authentication }
            let x = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
            let publicKey = signing.publicKey.rawRepresentation
            var signature = try signing.signature(for: x + identifier + publicKey)
            if tamper == .signature { signature[0] ^= 1 }
            let info = try OPACK.encode(.dictionary(["name": .string("Synthetic iPhone"), "model": .string("iPhone-test"), "remotepairing_udid": .string("test-phone"), "altIRK": .data(Data(repeating: 7, count: 16))]))
            let identity = TLV8.encode([(1, identifier), (3, publicKey), (10, signature), (17, info)])
            let key = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            try enqueue([(6, Data([5])), (5, PairingCrypto.seal(identity, key: key, nonce: PairingCrypto.nonce("PS-Msg05")))])
        case 6:
            guard let srp else { throw TVPairError.authentication }
            let key = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            let identity = try TLV8.decode(PairingCrypto.open(TLV8.require(values, 5), key: key, nonce: PairingCrypto.nonce("PS-Msg06")))
            let id = try TLV8.require(identity, 1), publicKey = try TLV8.require(identity, 3)
            let x = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            guard try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(TLV8.require(identity, 10), for: x + id + publicKey) else { throw TVPairError.authentication }
            hostVerified = true
        default: throw TVPairError.malformed("synthetic onboarding state")
        }
    }
}
