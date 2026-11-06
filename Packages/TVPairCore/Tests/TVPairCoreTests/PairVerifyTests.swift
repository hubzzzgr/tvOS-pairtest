import XCTest
import CryptoKit
@testable import TVPairCore

final class PairVerifyTests: XCTestCase {
    func testPinnedPeerAndHostProofsAreRequiredBeforeListenerCreation() async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: false)
        let record = await transport.record()
        let client = RemotePairingClient(transport: transport)
        let result = try await client.authenticate(endpoint: ConnectionEndpoint(host: "tv.local", port: "1234"), existingRecord: record, requestPIN: { XCTFail("Reconnect must not ask for a PIN"); throw TVPairError.authentication }, report: { _,_,_,_ in })
        XCTAssertEqual(result.id, record.id)
        let listener = try await client.createTunnelListener()
        XCTAssertEqual(listener.port, 54321); XCTAssertEqual(listener.key.count, 32)
        let hostVerified = await transport.hostWasVerified()
        XCTAssertTrue(hostVerified)
    }
    func testTamperedPeerSignatureIsRejectedWithoutFallbackOrListener() async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: true)
        // Use the same synthetic peer/record so that the only failure is the modified signature.
        let record = await transport.record(), actualClient = RemotePairingClient(transport: transport)
        do {
            _ = try await actualClient.authenticate(endpoint: ConnectionEndpoint(host: "tv.local", port: "1234"), existingRecord: record, requestPIN: { XCTFail("Failure must not prompt for a new PIN"); throw TVPairError.authentication }, report: { _,_,_,_ in })
            XCTFail("Tampered peer cannot authenticate")
        } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
        do { _ = try await actualClient.createTunnelListener(); XCTFail("Unauthenticated listener request") }
        catch { XCTAssertEqual(error as? TVPairError, .authentication) }
    }
}

private final class VerifyPeerTransport: ByteTransport, @unchecked Sendable {
    let peer: VerifyPeer
    init(tamperPeerSignature: Bool) { peer = VerifyPeer(tamper: tamperPeerSignature) }
    func record() async -> PairingRecord { await peer.record }
    func hostWasVerified() async -> Bool { await peer.hostVerified }
    func connect(timeout: TimeInterval) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: TimeInterval) async throws { try await peer.handle(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}

private actor VerifyPeer {
    let tamper: Bool
    let hostKey = Curve25519.Signing.PrivateKey()
    let peerKey = Curve25519.Signing.PrivateKey()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let peerID = Data("synthetic-peer".utf8)
    let hostID = UUID().uuidString
    var buffer = Data()
    var shared: Data?
    var hostEphemeral = Data()
    var hostVerified = false
    init(tamper: Bool) { self.tamper = tamper }
    var record: PairingRecord {
        PairingRecord(deviceName: "Synthetic peer", deviceIdentifier: "test-only", productType: "AppleTV-test", hostIdentifier: hostID, privateKey: hostKey.rawRepresentation, publicKey: hostKey.publicKey.rawRepresentation, peerPublicKey: peerKey.publicKey.rawRepresentation, peerIdentifier: peerID, alternateIRK: nil, endpoint: nil)
    }
    func take(_ count: Int) throws -> Data {
        guard buffer.count >= count else { throw TVPairError.closed }
        let output = Data(buffer.prefix(count)); buffer.removeFirst(count); return output
    }
    func enqueue(_ message: [String: Any]) throws {
        buffer += try FramedJSON.encode(["message": ["plain": ["_0": message]], "originatedBy": "device", "sequenceNumber": 0])
    }
    func tlv(_ values: [(UInt8, Data)]) throws {
        try enqueue(["event": ["_0": ["pairingData": ["_0": ["data": TLV8.encode(values).base64EncodedString()]]]]])
    }
    func handle(_ data: Data) throws {
        guard data.prefix(9) == Data("RPPairing".utf8),
              let envelope = try JSONSerialization.jsonObject(with: data.dropFirst(11)) as? [String: Any] else { throw TVPairError.malformed("test peer frame") }
        if let plain = nested(envelope, "message", "plain", "_0") as? [String: Any] {
            if nested(plain, "request", "_0", "handshake") != nil {
                try enqueue(["response": ["_1": ["handshake": ["_0": ["wireProtocolVersion": 19, "peerDeviceInfo": ["model": "AppleTV-test", "identifier": "test-only"]]]]]]); return
            }
            guard let encoded = nested(plain, "event", "_0", "pairingData", "_0", "data") as? String, let bytes = Data(base64Encoded: encoded) else { throw TVPairError.malformed("test peer TLV") }
            let values = try TLV8.decode(bytes)
            if values[6] == Data([1]) {
                hostEphemeral = try TLV8.require(values, 3, size: 32)
                let agreement = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEphemeral))
                let secret = agreement.withUnsafeBytes { Data($0) }; shared = secret
                var signature = try peerKey.signature(for: ephemeral.publicKey.rawRepresentation + peerID + hostEphemeral)
                if tamper { signature[0] ^= 1 }
                let verifyKey = PairingCrypto.derive(secret, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
                let payload = TLV8.encode([(1, peerID), (10, signature)])
                try tlv([(6, Data([2])), (3, ephemeral.publicKey.rawRepresentation), (5, PairingCrypto.seal(payload, key: verifyKey, nonce: PairingCrypto.nonce("PV-Msg02")))])
            } else if values[6] == Data([3]), let shared {
                let key = PairingCrypto.derive(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
                let payload = try TLV8.decode(PairingCrypto.open(try TLV8.require(values, 5), key: key, nonce: PairingCrypto.nonce("PV-Msg03")))
                guard payload[1] == Data(hostID.utf8), hostKey.publicKey.isValidSignature(try TLV8.require(payload, 10), for: hostEphemeral + Data(hostID.utf8) + ephemeral.publicKey.rawRepresentation) else { throw TVPairError.authentication }
                hostVerified = true; try tlv([(6, Data([4]))])
            } else { throw TVPairError.malformed("test peer state") }
        } else {
            guard hostVerified, let shared, let encoded = nested(envelope, "message", "streamEncrypted", "_0") as? String, let ciphertext = Data(base64Encoded: encoded) else { throw TVPairError.authentication }
            let nonce = Data(repeating: 0, count: 12)
            let request = try PairingCrypto.open(ciphertext, key: PairingCrypto.derive(shared, info: "ClientEncrypt-main"), nonce: nonce)
            guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any], nested(object, "request", "_0", "createListener", "key") as? String == shared.base64EncodedString() else { throw TVPairError.authentication }
            let response = try JSONSerialization.data(withJSONObject: ["response": ["_1": ["createListener": ["port": 54321]]]])
            let encrypted = try PairingCrypto.seal(response, key: PairingCrypto.derive(shared, info: "ServerEncrypt-main"), nonce: nonce)
            buffer += try FramedJSON.encode(["message": ["streamEncrypted": ["_0": encrypted.base64EncodedString()]], "originatedBy": "device", "sequenceNumber": 3])
        }
    }
}
