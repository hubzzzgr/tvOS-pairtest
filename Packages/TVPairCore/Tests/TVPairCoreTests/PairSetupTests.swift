import XCTest
import CryptoKit
import BigInt
@testable import TVPairCore

final class PairSetupTests: XCTestCase {
    func testFullSyntheticPINExchangeProducesAuthenticatedIdentity() async throws {
        let transport = SetupTransport(tamperProof: false)
        let client = RemotePairingClient(transport: transport), observed = ObservedStages()
        let record = try await client.authenticate(endpoint: ConnectionEndpoint(host: "tv.local", port: "1234"), requestPIN: { "123456" }, report: { stage, _, _, _ in await observed.add(stage) })
        XCTAssertEqual(record.deviceName, "Synthetic Apple TV"); XCTAssertEqual(record.deviceIdentifier, "synthetic-udid")
        let peerPublicKey = await transport.publicKey()
        XCTAssertEqual(record.peerPublicKey, peerPublicKey)
        XCTAssertNotNil(record.pairedAt); try record.validate()
        let stages = await observed.values
        XCTAssertTrue(stages.contains(.awaitingPIN)); XCTAssertTrue(stages.contains(.authenticating))
    }
    func testBadSRPServerProofNeverProducesRecord() async throws {
        let transport = SetupTransport(tamperProof: true)
        let actual = RemotePairingClient(transport: transport)
        do {
            _ = try await actual.authenticate(endpoint: ConnectionEndpoint(host: "tv.local", port: "1234"), requestPIN: { "123456" }, report: { _,_,_,_ in })
            XCTFail("Server proof mismatch must prevent record creation")
        } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
        do { _ = try await actual.createTunnelListener(); XCTFail("Unauthenticated client cannot create a tunnel") } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
    }
}

private actor ObservedStages {
    var values: [PairingStage] = []
    func add(_ value: PairingStage) { values.append(value) }
}
private final class SetupTransport: ByteTransport, @unchecked Sendable {
    let server: SetupPeer
    init(tamperProof: Bool) { server = SetupPeer(tamperProof: tamperProof) }
    func publicKey() async -> Data { await server.signingKey.publicKey.rawRepresentation }
    func connect(timeout: TimeInterval) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: TimeInterval) async throws { try await server.handle(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await server.take(count) }
    func cancel() {}
}

private actor SetupPeer {
    let tamperProof: Bool
    let signingKey = Curve25519.Signing.PrivateKey()
    let salt = Data(0..<16)
    let b = BigUInt(Data((1...128).reversed().map { UInt8($0) }))
    let peerID = Data("synthetic-peer-account".utf8)
    var sessionKey: Data?
    var buffer = Data()
    var pairingKind = ""
    init(tamperProof: Bool) { self.tamperProof = tamperProof }
    func take(_ count: Int) throws -> Data {
        guard buffer.count >= count else { throw TVPairError.closed }
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    func plain(_ message: [String: Any]) throws { buffer += try FramedJSON.encode(["originatedBy": "device", "sequenceNumber": 0, "message": ["plain": ["_0": message]]]) }
    func tlv(_ entries: [(UInt8, Data)]) throws { try plain(["event": ["_0": ["pairingData": ["_0": ["data": TLV8.encode(entries).base64EncodedString()]]]]]) }
    func parameters() -> (verifier: BigUInt, publicKey: BigUInt) {
        let n = SRPSession.prime, g = BigUInt(5)
        let x = BigUInt(PairingCrypto.hash(salt + PairingCrypto.hash(Data("Pair-Setup:123456".utf8))))
        let verifier = g.power(x, modulus: n)
        let k = BigUInt(PairingCrypto.hash(SRPSession.bytes(n) + SRPSession.padded(g)))
        return (verifier, (k * verifier + g.power(b, modulus: n)) % n)
    }
    func handle(_ frame: Data) throws {
        guard let envelope = try JSONSerialization.jsonObject(with: frame.dropFirst(11)) as? [String: Any], let message = nested(envelope, "message", "plain", "_0") as? [String: Any] else { throw TVPairError.malformed("synthetic setup frame") }
        if nested(message, "request", "_0", "handshake") != nil {
            try plain(["response": ["_1": ["handshake": ["_0": ["wireProtocolVersion": 19, "peerDeviceInfo": ["model": "AppleTV-test", "identifier": "synthetic-udid"]]]]]]); return
        }
        if nested(message, "event", "_0", "pairVerifyFailed") != nil { return }
        guard let kind = nested(message, "event", "_0", "pairingData", "_0", "kind") as? String, let encoded = nested(message, "event", "_0", "pairingData", "_0", "data") as? String, let data = Data(base64Encoded: encoded) else { throw TVPairError.malformed("synthetic setup TLV") }
        let values = try TLV8.decode(data)
        if kind == "verifyManualPairing" { try tlv([(6, Data([2]))]); return }
        let p = parameters(), n = SRPSession.prime
        switch values[6]?.first {
        case 1: try tlv([(6, Data([2])), (2, salt), (3, SRPSession.bytes(p.publicKey))])
        case 3:
            let a = BigUInt(try TLV8.require(values, 3))
            let u = BigUInt(PairingCrypto.hash(SRPSession.padded(a) + SRPSession.padded(p.publicKey)))
            let shared = (a * p.verifier.power(u, modulus: n)).power(b, modulus: n)
            let key = PairingCrypto.hash(SRPSession.bytes(shared)); sessionKey = key
            let group = BigUInt(PairingCrypto.hash(SRPSession.bytes(n))) ^ BigUInt(PairingCrypto.hash(Data([5])))
            let expected = PairingCrypto.hash(SRPSession.bytes(group) + SRPSession.bytes(BigUInt(PairingCrypto.hash(Data("Pair-Setup".utf8)))) + salt + SRPSession.bytes(a) + SRPSession.bytes(p.publicKey) + key)
            guard PairingCrypto.equal(try TLV8.require(values, 4), expected) else { throw TVPairError.authentication }
            var proof = PairingCrypto.hash(SRPSession.bytes(a) + expected + key)
            if tamperProof { proof[0] ^= 1 }
            try tlv([(6, Data([4])), (4, proof)])
        case 5:
            guard let sessionKey else { throw TVPairError.authentication }
            let setupKey = PairingCrypto.derive(sessionKey, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
            let host = try TLV8.decode(PairingCrypto.open(try TLV8.require(values, 5), key: setupKey, nonce: PairingCrypto.nonce("PS-Msg05")))
            let identifier = try TLV8.require(host, 1), publicKey = try TLV8.require(host, 3, size: 32)
            let sign = PairingCrypto.derive(sessionKey, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
            guard try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(TLV8.require(host, 10), for: sign + identifier + publicKey) else { throw TVPairError.authentication }
            let peerSign = PairingCrypto.derive(sessionKey, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
            let peerKey = signingKey.publicKey.rawRepresentation
            let signature = try signingKey.signature(for: peerSign + peerID + peerKey)
            let info = try OPACK.encode(.dictionary(["name": .string("Synthetic Apple TV"), "model": .string("AppleTV-test"), "remotepairing_udid": .string("synthetic-udid"), "accountID": .string("synthetic-peer-account"), "altIRK": .data(Data(repeating: 7, count: 16))]))
            let identity = TLV8.encode([(1, peerID), (3, peerKey), (10, signature), (17, info)])
            try tlv([(6, Data([6])), (5, PairingCrypto.seal(identity, key: setupKey, nonce: PairingCrypto.nonce("PS-Msg06")))])
        default: throw TVPairError.malformed("synthetic setup state")
        }
    }
}
