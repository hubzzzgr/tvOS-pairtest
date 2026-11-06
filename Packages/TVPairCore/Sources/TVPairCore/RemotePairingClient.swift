import Foundation
import CryptoKit

public typealias PairingReporter = @Sendable (PairingStage, DiagnosticCheck, CheckResult, String) async -> Void

/// Native experimental RPPairing control plane; no lockdown, AirPlay, or private frameworks.
/// Protocol envelopes and stages were checked against MIT-licensed idevice (see THIRD_PARTY_NOTICES).
public actor RemotePairingClient {
    private let transport: any ByteTransport
    private var sequence: UInt64 = 0
    private var encryptedSequence: UInt64 = 0
    private var sessionKey: Data?
    private var peerInfo: [String: Any] = [:]
    private var authenticated = false
    public init(transport: any ByteTransport) { self.transport = transport }
    public nonisolated func cancel() { transport.cancel() }

    private func sendPlain(_ message: [String: Any]) async throws {
        let envelope: [String: Any] = ["message": ["plain": ["_0": message]], "originatedBy": "host", "sequenceNumber": sequence]
        sequence += 1
        try await transport.send(FramedJSON.encode(envelope), timeout: 10)
    }
    private func receivePlain(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let envelope = try await FramedJSON.receive(from: transport, timeout: timeout)
        guard envelope["originatedBy"] as? String == "device", let plain = nested(envelope, "message", "plain", "_0") as? [String: Any] else { throw TVPairError.malformed("plain device envelope") }
        return plain
    }
    private func sendTLV(_ values: [(UInt8, Data)], kind: String, newSession: Bool) async throws {
        try await sendPlain(["event": ["_0": ["pairingData": ["_0": [
            "data": TLV8.encode(values).base64EncodedString(), "kind": kind,
            "sendingHost": "TVPair", "startNewSession": newSession
        ]]]]])
    }
    private func receiveTLV(timeout: TimeInterval = 10) async throws -> [UInt8: Data] {
        var plain = try await receivePlain(timeout: timeout)
        if nested(plain, "event", "_0", "awaitingUserConsent") != nil { plain = try await receivePlain(timeout: 90) }
        if nested(plain, "event", "_0", "pairingRejectedWithError") != nil { throw TVPairError.rejected(-1, nil) }
        guard let string = nested(plain, "event", "_0", "pairingData", "_0", "data") as? String,
              let bytes = Data(base64Encoded: string) else { throw TVPairError.malformed("pairing event") }
        return try TLV8.decode(bytes)
    }

    public func authenticate(endpoint: ConnectionEndpoint, existingRecord: PairingRecord? = nil, requestPIN: @Sendable () async throws -> String, report: PairingReporter) async throws -> PairingRecord {
        guard sequence == 0 else { throw TVPairError.malformed("a new transport is required for every session") }
        try Task.checkCancellation()
        await report(.connecting, .tcp, .running, "Opening the advertised TCP endpoint.")
        try await transport.connect(timeout: 10)
        await report(.connecting, .resolution, .passed, "The endpoint resolved as part of the established TCP connection.")
        await report(.connecting, .tcp, .passed, "TCP is connected. Authentication has not yet succeeded.")
        await report(.negotiating, .initiation, .running, "Negotiating RPPairing wire protocol version 19.")
        try await sendPlain(["request": ["_0": ["handshake": ["_0": ["hostOptions": ["attemptPairVerify": true], "wireProtocolVersion": 19]]]]])
        let handshake = try await receivePlain()
        guard let info = nested(handshake, "response", "_1", "handshake", "_0") as? [String: Any],
              let peer = info["peerDeviceInfo"] as? [String: Any], let model = peer["model"] as? String else { throw TVPairError.malformed("handshake peerDeviceInfo") }
        if let version = info["wireProtocolVersion"] as? Int, version != 19 { throw TVPairError.unsupported("peer wire protocol version \(version)") }
        peerInfo = peer
        await report(.verifying, .initiation, .passed, "RPPairing handshake received. Peer metadata remains unverified.")

        if var record = existingRecord {
            try record.validate()
            // Legacy pymobiledevice3/idevice records omit the peer key. Do not silently skip peer authentication.
            guard record.peerPublicKey != nil && record.peerIdentifier != nil else { throw TVPairError.unsupported("this imported record lacks the peer signing key; create a fresh PIN pairing to establish peer identity") }
            await report(.verifying, .authentication, .running, "Verifying the saved host credentials and pinned peer signing key.")
            try await verify(record)
            record.lastEndpoint = endpoint; authenticated = true
            await report(.verifying, .authentication, .passed, "Pair-Verify completed and the peer signature matched the saved identity.")
            return record
        }

        // The initial verify attempt is part of the observed protocol, even for a new host.
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        try await sendTLV([(6, Data([1])), (3, ephemeral.publicKey.rawRepresentation)], kind: "verifyManualPairing", newSession: true)
        let first = try await receiveTLV()
        if first[7] == nil { try TLV8.check(first, state: 2) }
        try await sendPlain(["event": ["_0": ["pairVerifyFailed": [:]]]])

        await report(.requestingConsent, .authentication, .running, "Requesting a new manual pairing session from the device.")
        try await sendTLV([(0, Data([0])), (6, Data([1]))], kind: "setupManualPairing", newSession: true)
        let challenge = try await receiveTLV(timeout: 90)
        try TLV8.check(challenge, state: 2)
        let serverPublic = try TLV8.require(challenge, 3), salt = try TLV8.require(challenge, 2)
        guard model.hasPrefix("AppleTV") else { throw TVPairError.unsupported("the peer did not identify as an Apple TV; this client does not infer a PIN flow for other models") }
        await report(.awaitingPIN, .authentication, .running, "The device supplied a manual pairing challenge. Enter the code displayed on Apple TV.")
        let pin = try await requestPIN()
        try Task.checkCancellation()
        await report(.authenticating, .authentication, .running, "Deriving the SRP session and checking the server proof.")
        // Modular exponentiation stays away from the main actor.
        let srp = try await Task.detached { try SRPSession(pin: pin, serverPublic: serverPublic, salt: salt) }.value
        try Task.checkCancellation()
        try await sendTLV([(6, Data([3])), (3, srp.publicKey), (4, srp.proof)], kind: "setupManualPairing", newSession: false)
        let proof = try await receiveTLV(); try TLV8.check(proof, state: 4)
        guard srp.verify(try TLV8.require(proof, 4, size: 64)) else { throw TVPairError.authentication }

        let hostID = UUID().uuidString.uppercased(), signingKey = Curve25519.Signing.PrivateKey()
        let signingPublic = signingKey.publicKey.rawRepresentation
        let controllerSign = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let signature = try signingKey.signature(for: controllerSign + Data(hostID.utf8) + signingPublic)
        let localInfo = try OPACK.encode(.dictionary([
            "altIRK": .data(try PairingCrypto.random(16)), "accountID": .string(hostID),
            "model": .string("iPhone"), "name": .string("TVPair"),
            // Synthetic protocol identity metadata, never presented as retrieved device properties.
            "btAddr": .string("00:00:00:00:00:00"), "mac": .data(Data(repeating: 0, count: 6)),
            "remotepairing_serial_number": .string(hostID)
        ]))
        let identity = TLV8.encode([(1, Data(hostID.utf8)), (3, signingPublic), (10, signature), (17, localInfo)])
        let setupKey = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let sealed = try PairingCrypto.seal(identity, key: setupKey, nonce: PairingCrypto.nonce("PS-Msg05"))
        try await sendTLV([(5, sealed), (6, Data([5]))], kind: "setupManualPairing", newSession: false)
        let final = try await receiveTLV(); try TLV8.check(final, state: 6)
        let peerIdentity = try TLV8.decode(PairingCrypto.open(try TLV8.require(final, 5), key: setupKey, nonce: PairingCrypto.nonce("PS-Msg06")))
        let peerID = try TLV8.require(peerIdentity, 1), peerKey = try TLV8.require(peerIdentity, 3, size: 32)
        let peerSignature = try TLV8.require(peerIdentity, 10, size: 64)
        let accessorySign = PairingCrypto.derive(srp.key, salt: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: peerKey)
        guard verifier.isValidSignature(peerSignature, for: accessorySign + peerID + peerKey) else { throw TVPairError.authentication }
        var metadata: [String: OPACKValue] = [:]
        if let info = peerIdentity[17] {
            if case let .dictionary(values) = try OPACK.decode(info) { metadata = values }
        }
        let record = PairingRecord(
            deviceName: displayText(metadata["name"]?.string ?? "Unavailable"),
            deviceIdentifier: displayText(metadata["remotepairing_udid"]?.string ?? "Unavailable"),
            productType: metadata["model"]?.string.map(displayText), hostIdentifier: hostID,
            privateKey: signingKey.rawRepresentation, publicKey: signingPublic,
            peerPublicKey: peerKey, peerIdentifier: peerID,
            alternateIRK: metadata["altIRK"]?.data, endpoint: endpoint)
        try record.validate(); sessionKey = srp.key; authenticated = true
        await report(.authenticating, .authentication, .passed, "The server proof and encrypted peer identity signature were verified. Pair-Setup completed.")
        return record
    }

    private func verify(_ record: PairingRecord) async throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), ownPublic = key.publicKey.rawRepresentation
        try await sendTLV([(6, Data([1])), (3, ownPublic)], kind: "verifyManualPairing", newSession: true)
        let response = try await receiveTLV(); try TLV8.check(response, state: 2)
        let peerEphemeral = try TLV8.require(response, 3, size: 32)
        let agreement = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral))
        let shared = agreement.withUnsafeBytes { Data($0) }
        guard shared.contains(where: { $0 != 0 }) else { throw TVPairError.authentication }
        let verifyKey = PairingCrypto.derive(shared, salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let identity = try TLV8.decode(PairingCrypto.open(try TLV8.require(response, 5), key: verifyKey, nonce: PairingCrypto.nonce("PV-Msg02")))
        let peerID = try TLV8.require(identity, 1), signature = try TLV8.require(identity, 10, size: 64)
        guard let pinnedKey = record.peerPublicKey, let pinnedID = record.peerIdentifier,
              PairingCrypto.equal(peerID, pinnedID),
              try Curve25519.Signing.PublicKey(rawRepresentation: pinnedKey).isValidSignature(signature, for: peerEphemeral + peerID + ownPublic) else { throw TVPairError.authentication }
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: record.privateKey)
        let ownSignature = try signing.signature(for: ownPublic + Data(record.hostIdentifier.utf8) + peerEphemeral)
        let payload = TLV8.encode([(1, Data(record.hostIdentifier.utf8)), (10, ownSignature)])
        try await sendTLV([(6, Data([3])), (5, PairingCrypto.seal(payload, key: verifyKey, nonce: PairingCrypto.nonce("PV-Msg03")))], kind: "verifyManualPairing", newSession: false)
        let final = try await receiveTLV(); try TLV8.check(final, state: 4)
        sessionKey = shared
    }

    public func createTunnelListener() async throws -> (port: UInt16, key: Data) {
        guard authenticated, let key = sessionKey else { throw TVPairError.authentication }
        var number = encryptedSequence.littleEndian
        let nonce = withUnsafeBytes(of: &number) { Data($0) } + Data(repeating: 0, count: 4)
        let request: [String: Any] = ["request": ["_0": ["createListener": ["key": key.base64EncodedString(), "transportProtocolType": "tcp"]]]]
        let encrypted = try PairingCrypto.seal(JSONSerialization.data(withJSONObject: request), key: PairingCrypto.derive(key, info: "ClientEncrypt-main"), nonce: nonce)
        let envelope: [String: Any] = ["message": ["streamEncrypted": ["_0": encrypted.base64EncodedString()]], "originatedBy": "host", "sequenceNumber": sequence]
        sequence += 1; encryptedSequence += 1
        try await transport.send(FramedJSON.encode(envelope), timeout: 10)
        let response = try await FramedJSON.receive(from: transport)
        guard response["originatedBy"] as? String == "device", let encoded = nested(response, "message", "streamEncrypted", "_0") as? String, let ciphertext = Data(base64Encoded: encoded) else { throw TVPairError.malformed("encrypted envelope") }
        let plaintext = try PairingCrypto.open(ciphertext, key: PairingCrypto.derive(key, info: "ServerEncrypt-main"), nonce: nonce)
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let port = nested(object, "response", "_1", "createListener", "port") as? Int,
              let valid = UInt16(exactly: port), valid > 0 else { throw TVPairError.unsupported("the authenticated endpoint did not provide a TCP tunnel listener; on tvOS select the regular Remote Pairing advertisement and reconnect with the saved record") }
        return (valid, key)
    }
}
