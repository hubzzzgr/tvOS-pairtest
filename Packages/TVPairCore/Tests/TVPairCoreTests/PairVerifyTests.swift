import XCTest
import CryptoKit
@testable import TVPairCore

final class PairVerifyTests: XCTestCase {
    func testReconnectWithoutHandshakeModelStillVerifiesPinnedIdentityAndCreatesListener() async throws {
        try await verifySparseHandshake(.withoutModel)
    }
    func testReconnectWithoutHandshakeMetadataStillVerifiesPinnedIdentityAndCreatesListener() async throws {
        try await verifySparseHandshake(.withoutMetadata)
    }
    private func verifySparseHandshake(_ handshake: VerifyPeer.Handshake) async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: false, handshake: handshake)
        let record = await transport.record(), client = RemotePairingClient(transport: transport)
        let verified = try await client.authenticate(endpoint: ConnectionEndpoint(host: "phone.local", port: "49152"), service: .remotePairing, existingRecord: record, requestPIN: { XCTFail("Saved-record verification must not request a code"); throw TVPairError.authentication }, report: { _,_,_,_ in })
        XCTAssertEqual(verified.peerPublicKey, record.peerPublicKey)
        let hostVerified = await transport.hostWasVerified(); XCTAssertTrue(hostVerified)
        let listener = try await client.createTunnelListener(); XCTAssertEqual(listener.port, 54321)
    }
    func testSparseHandshakeDoesNotBypassPeerSignatureVerification() async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: true, handshake: .withoutMetadata)
        let record = await transport.record(), client = RemotePairingClient(transport: transport)
        do {
            _ = try await client.authenticate(endpoint: ConnectionEndpoint(host: "phone.local", port: "49152"), existingRecord: record, requestPIN: { throw TVPairError.authentication }, report: { _,_,_,_ in })
            XCTFail("Missing metadata must not bypass pinned-peer authentication")
        } catch { XCTAssertEqual(error as? TVPairError, .authentication) }
        do { _ = try await client.createTunnelListener(); XCTFail("Unauthenticated listener request") }
        catch { XCTAssertEqual(error as? TVPairError, .authentication) }
    }
    func testInvalidHandshakeEnvelopeIsRejectedBeforePairVerify() async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: false, handshake: .invalidEnvelope)
        let record = await transport.record(), client = RemotePairingClient(transport: transport)
        do {
            _ = try await client.authenticate(endpoint: ConnectionEndpoint(host: "phone.local", port: "49152"), existingRecord: record, requestPIN: { throw TVPairError.authentication }, report: { _,_,_,_ in })
            XCTFail("An actual handshake response is still required")
        } catch { XCTAssertEqual(error as? TVPairError, .malformed("handshake response envelope")) }
        let hostVerified = await transport.hostWasVerified(); XCTAssertFalse(hostVerified)
    }
    func testNewAppleTVPairingStillRequiresAnAdvertisedAppleTVModel() async throws {
        let transport = VerifyPeerTransport(tamperPeerSignature: false, handshake: .withoutMetadata)
        let client = RemotePairingClient(transport: transport)
        do {
            _ = try await client.authenticate(endpoint: ConnectionEndpoint(host: "phone.local", port: "49152"), service: .manualPairing, requestPIN: { XCTFail("Unknown models must not request a TV code"); return "123456" }, report: { _,_,_,_ in })
            XCTFail("The TV PIN flow must not infer a device type from a missing model")
        } catch { guard case .some(.unsupported(_)) = error as? TVPairError else { return XCTFail("Expected unsupported TV setup") } }
        let hostVerified = await transport.hostWasVerified(); XCTAssertFalse(hostVerified)
    }
    func testTunnelReconnectReportsCannotOverwriteCompletedPairingChecks() async throws {
        let reports = ReconnectReports()
        let reporter = tunnelReconnectReporter { stage, check, result, _ in await reports.append(stage, check, result) }
        await reporter(.connecting, .tcp, .passed, "TCP connected")
        await reporter(.negotiating, .initiation, .running, "Handshake")
        await reporter(.verifying, .initiation, .passed, "Handshake received")
        await reporter(.verifying, .authentication, .passed, "Peer verified")
        await reporter(.connecting, .resolution, .passed, "Outbound endpoint resolved")
        let values = await reports.values
        XCTAssertEqual(values.count, 5)
        XCTAssertTrue(values.prefix(4).allSatisfy { $0.0 == .openingTunnel && $0.1 == .tunnel && $0.2 == .running })
        XCTAssertEqual(values.last?.0, .openingTunnel)
        XCTAssertEqual(values.last?.1, .resolution)
        XCTAssertEqual(values.last?.2, .passed)
    }
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
    init(tamperPeerSignature: Bool, handshake: VerifyPeer.Handshake = .full) { peer = VerifyPeer(tamper: tamperPeerSignature, handshake: handshake) }
    func record() async -> PairingRecord { await peer.record }
    func hostWasVerified() async -> Bool { await peer.hostVerified }
    func connect(timeout: TimeInterval) async throws { try Task.checkCancellation() }
    func send(_ data: Data, timeout: TimeInterval) async throws { try await peer.handle(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}

private actor VerifyPeer {
    enum Handshake: Sendable { case full, withoutModel, withoutMetadata, invalidEnvelope }
    let handshake: Handshake
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
    init(tamper: Bool, handshake: Handshake) { self.tamper = tamper; self.handshake = handshake }
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
                var info: [String: Any] = ["wireProtocolVersion": 26, "minimumSupportedWireProtocolVersion": 8]
                switch handshake {
                case .full: info["peerDeviceInfo"] = ["model": "AppleTV-test", "identifier": "test-only"]
                case .withoutModel: info["peerDeviceInfo"] = ["identifier": "test-only"]
                case .withoutMetadata: break
                case .invalidEnvelope: try enqueue(["event": [:]]); return
                }
                try enqueue(["response": ["_1": ["handshake": ["_0": info]]]]); return
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

private actor ReconnectReports {
    var values: [(PairingStage, DiagnosticCheck, CheckResult)] = []
    func append(_ stage: PairingStage, _ check: DiagnosticCheck, _ result: CheckResult) { values.append((stage, check, result)) }
}
