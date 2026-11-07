import Foundation
import CryptoKit

public struct PairableHostIdentity: Sendable {
    public let name: String
    public let identifier: String
    let privateKey: Data
    let alternateIRK: Data
    public init(name: String = "TVPair") throws {
        self.name = name; identifier = UUID().uuidString.uppercased()
        privateKey = Curve25519.Signing.PrivateKey().rawRepresentation
        alternateIRK = try PairingCrypto.random(16)
    }
    public var txtRecords: [String: Data] {
        ["name": name, "identifier": identifier, "authTag": AdvertisementIdentity.tag(key: alternateIRK, identifier: identifier).base64EncodedString(),
         "model": "Mac17,7", "flags": "1", "ver": "26", "minVer": "19"].mapValues { Data($0.utf8) }
    }
}

/// Responder role from idevice's MIT-licensed remote_pairing/responder.rs.
/// The remote iPhone is the wire "host"; TVPair replies as the wire "device".
public actor PairableHostSession {
    private let transport: any ByteTransport
    private let identity: PairableHostIdentity
    private var sequence: UInt64 = 0
    public init(transport: any ByteTransport, identity: PairableHostIdentity) { self.transport = transport; self.identity = identity }
    private func receive(timeout: TimeInterval = 15) async throws -> [String: Any] {
        let envelope = try await FramedJSON.receive(from: transport, timeout: timeout)
        guard envelope["originatedBy"] as? String == "host", let plain = nested(envelope, "message", "plain", "_0") as? [String: Any] else { throw TVPairError.malformed("device-initiated host envelope") }
        return plain
    }
    private func send(_ plain: [String: Any]) async throws {
        let frame = try FramedJSON.encode(["originatedBy": "device", "sequenceNumber": sequence, "message": ["plain": ["_0": plain]]])
        sequence += 1; try await transport.send(frame, timeout: 10)
    }
    private func receiveTLV(timeout: TimeInterval = 15) async throws -> [UInt8: Data] {
        let plain = try await receive(timeout: timeout)
        guard let event = nested(plain, "event", "_0", "pairingData", "_0") as? [String: Any],
              event["kind"] as? String == "setupManualPairing", let encoded = event["data"] as? String,
              let data = Data(base64Encoded: encoded) else { throw TVPairError.malformed("device-initiated setup event") }
        return try TLV8.decode(data)
    }
    private func sendTLV(_ entries: [(UInt8, Data)]) async throws {
        try await send(["event": ["_0": ["pairingData": ["_0": ["kind": "setupManualPairing", "startNewSession": false, "data": TLV8.encode(entries).base64EncodedString()]]]]])
    }
    public func accept(displayPIN: @Sendable (String?) async -> Void, report: PairingReporter) async throws -> PairingRecord {
        guard sequence == 0 else { throw TVPairError.malformed("host session already used") }
        await report(.connecting, .tcp, .running, "Accepting the device-initiated TCP connection.")
        try await transport.connect(timeout: 10)
        await report(.connecting, .tcp, .passed, "The other device connected to TVPair's advertised host endpoint.")
        await report(.connecting, .resolution, .notAttempted, "Incoming connection; no outbound DNS lookup was required. A later outbound reconnect tests resolution separately.")
        await report(.negotiating, .initiation, .running, "Waiting for the other device's RPPairing handshake.")
        let request = try await receive()
        guard let handshake = nested(request, "request", "_0", "handshake", "_0") as? [String: Any],
              let version = handshake["wireProtocolVersion"] as? Int, (19...26).contains(version),
              nested(handshake, "hostOptions", "attemptPairVerify") as? Bool != true else { throw TVPairError.unsupported("this listener accepts new device-initiated setup using wire versions 19 through 26; use a saved record on the regular endpoint for reconnect") }
        try await send(["response": ["forRequestIdentifier": 0, "_1": ["handshake": ["_0": [
            "wireProtocolVersion": 26, "minimumSupportedWireProtocolVersion": 19,
            "deviceOptions": ["allowsPairSetup": true, "allowsPinlessPairing": false, "allowsIncomingTunnelConnections": false, "allowsUpgradeOfLockdownPairings": false, "allowsSharingSensitiveInfo": false],
            "peerDeviceInfo": ["udid": "", "identifier": identity.identifier, "name": identity.name, "model": "Mac17,7", "deviceKVSIncludesSensitiveInfo": false]
        ]]]]])
        await report(.requestingConsent, .initiation, .passed, "The device-initiated pairing handshake completed. Waiting for its setup request.")
        let m1 = try await receiveTLV(); try TLV8.check(m1, state: 1)
        guard m1[0] == Data([0]) else { throw TVPairError.unsupported("device-initiated setup method") }
        let pin = String(format: "%06u", UInt32.random(in: 0..<1_000_000))
        let srp = try await Task.detached { try SRPServerSession(pin: pin) }.value
        try Task.checkCancellation()
        await displayPIN(pin)
        await report(.displayingPIN, .authentication, .running, "Enter TVPair's displayed code on the other iPhone or iPad. The code is not entered in this app.")
        try await sendTLV([(6, Data([2])), (2, srp.salt), (3, srp.publicKey)])
        let m3: [UInt8: Data]
        do { m3 = try await receiveTLV(timeout: 90) }
        catch { await displayPIN(nil); throw error }
        await displayPIN(nil); try TLV8.check(m3, state: 3)
        await report(.authenticating, .authentication, .running, "Checking the device's SRP proof and signed identity.")
        let verified: (key: Data, proof: Data)
        do { verified = try srp.process(clientPublic: TLV8.require(m3, 3), clientProof: TLV8.require(m3, 4, size: 64)) }
        catch {
            try? await sendTLV([(6, Data([4])), (7, Data([2]))]); throw TVPairError.authentication
        }
        try await sendTLV([(6, Data([4])), (4, verified.proof)])
        let key = PairingCrypto.derive(verified.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let m5 = try await receiveTLV(); try TLV8.check(m5, state: 5)
        let peer = try TLV8.decode(PairingCrypto.open(try TLV8.require(m5, 5), key: key, nonce: PairingCrypto.nonce("PS-Msg05")))
        let peerID = try TLV8.require(peer, 1), peerKey = try TLV8.require(peer, 3, size: 32)
        let signature = try TLV8.require(peer, 10, size: 64)
        let controllerX = PairingCrypto.derive(verified.key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        guard try Curve25519.Signing.PublicKey(rawRepresentation: peerKey).isValidSignature(signature, for: controllerX + peerID + peerKey) else { throw TVPairError.authentication }
        guard case let .dictionary(metadata) = try OPACK.decode(TLV8.require(peer, 17)) else { throw TVPairError.malformed("device identity metadata") }
        let peerIRK = metadata["altIRK"]?.data
        guard peerIRK?.count == 16 else { throw TVPairError.malformed("device identity key") }
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: identity.privateKey), ownPublic = signing.publicKey.rawRepresentation
        let accessoryX = PairingCrypto.derive(verified.key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let ownSignature = try signing.signature(for: accessoryX + Data(identity.identifier.utf8) + ownPublic)
        let info = try OPACK.encode(.dictionary([
            "altIRK": .data(identity.alternateIRK), "accountID": .string(identity.identifier), "name": .string(identity.name),
            "model": .string("Mac17,7"), "remotepairing_udid": .string(""), "remotepairing_serial_number": .string(identity.identifier),
            "btAddr": .string("00:00:00:00:00:00"), "mac": .data(Data(repeating: 0, count: 6))
        ]))
        let ownIdentity = TLV8.encode([(1, Data(identity.identifier.utf8)), (3, ownPublic), (10, ownSignature), (17, info)])
        try await sendTLV([(6, Data([6])), (5, PairingCrypto.seal(ownIdentity, key: key, nonce: PairingCrypto.nonce("PS-Msg06")))])
        let record = PairingRecord(deviceName: displayText(metadata["name"]?.string ?? "Unavailable"), deviceIdentifier: displayText(metadata["remotepairing_udid"]?.string ?? "Unavailable"), productType: metadata["model"]?.string.map(displayText), hostIdentifier: identity.identifier, privateKey: identity.privateKey, publicKey: ownPublic, peerPublicKey: peerKey, peerIdentifier: peerID, alternateIRK: peerIRK, endpoint: nil)
        try record.validate()
        await report(.authenticating, .authentication, .passed, "Device-initiated SRP setup completed and the device's identity signature was verified.")
        return record
    }
}
