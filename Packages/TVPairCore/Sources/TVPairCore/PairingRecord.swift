import Foundation
import CryptoKit

/// Keys match idevice RpPairingFile; extensions preserve the peer's identity and provenance.
/// Importing a record never sets an authenticated status.
public struct PairingRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var deviceName: String
    public var deviceIdentifier: String
    public var productType: String?
    public var pairedAt: Date?
    public var importedAt: Date?
    public var hostIdentifier: String
    public var privateKey: Data
    public var publicKey: Data
    public var peerPublicKey: Data?
    public var peerIdentifier: Data?
    public var alternateIRK: Data?
    public var lastEndpoint: ConnectionEndpoint?

    public init(deviceName: String, deviceIdentifier: String, productType: String?, hostIdentifier: String, privateKey: Data, publicKey: Data, peerPublicKey: Data?, peerIdentifier: Data?, alternateIRK: Data?, endpoint: ConnectionEndpoint?) {
        id = UUID(); self.deviceName = deviceName; self.deviceIdentifier = deviceIdentifier; self.productType = productType
        pairedAt = Date(); importedAt = nil; self.hostIdentifier = hostIdentifier; self.privateKey = privateKey; self.publicKey = publicKey
        self.peerPublicKey = peerPublicKey; self.peerIdentifier = peerIdentifier; self.alternateIRK = alternateIRK; lastEndpoint = endpoint
    }
    public func validate() throws {
        guard privateKey.count == 32, publicKey.count == 32,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              PairingCrypto.equal(key.publicKey.rawRepresentation, publicKey) else { throw TVPairError.invalidRecord("Ed25519 key pair does not match") }
        guard !hostIdentifier.isEmpty, hostIdentifier.utf8.count <= 256, !hostIdentifier.contains(where: { $0.isNewline }) else { throw TVPairError.invalidRecord("host identifier required") }
        guard alternateIRK == nil || alternateIRK?.count == 16, peerPublicKey == nil || peerPublicKey?.count == 32,
              peerIdentifier == nil || (peerIdentifier!.count > 0 && peerIdentifier!.count <= 256) else { throw TVPairError.invalidRecord("identity material has invalid lengths") }
        if let endpoint = lastEndpoint { _ = try ConnectionEndpoint(host: endpoint.host, port: String(endpoint.port)) }
    }
    public func exportPlist() throws -> Data {
        try validate()
        var values: [String: Any] = [
            "public_key": publicKey, "private_key": privateKey,
            "identifier": hostIdentifier, "host_identifier": hostIdentifier,
            "remote_unlock_host_key": "", "tvpair_schema": 1,
            "tvpair_id": id.uuidString, "tvpair_device_name": deviceName,
            "tvpair_device_identifier": deviceIdentifier
        ]
        if let pairedAt { values["tvpair_paired_at"] = pairedAt }
        if let productType { values["tvpair_product_type"] = productType }
        if let peerPublicKey { values["tvpair_peer_public_key"] = peerPublicKey }
        if let peerIdentifier { values["tvpair_peer_identifier"] = peerIdentifier }
        if let alternateIRK { values["alt_irk"] = alternateIRK }
        if let endpoint = lastEndpoint { values["tvpair_host"] = endpoint.host; values["tvpair_port"] = Int(endpoint.port) }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }
    public static func importPlist(_ data: Data) throws -> PairingRecord {
        guard data.count <= 1_048_576 else { throw TVPairError.invalidRecord("file exceeds one MiB") }
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let privateKey = values["private_key"] as? Data, let publicKey = values["public_key"] as? Data,
              let identifier = (values["identifier"] ?? values["host_identifier"]) as? String else {
            throw TVPairError.invalidRecord("expected a Remote Pairing plist with public_key, private_key and identifier; USB lockdown records are incompatible")
        }
        if let schema = values["tvpair_schema"] as? Int, schema != 1 { throw TVPairError.invalidRecord("unknown TVPair schema") }
        var endpoint: ConnectionEndpoint?
        if let host = values["tvpair_host"] as? String, let port = values["tvpair_port"] as? Int { endpoint = try ConnectionEndpoint(host: host, port: String(port)) }
        var record = PairingRecord(
            deviceName: displayText(values["tvpair_device_name"] as? String ?? "Imported device"),
            deviceIdentifier: displayText(values["tvpair_device_identifier"] as? String ?? "Unavailable"),
            productType: (values["tvpair_product_type"] as? String).map(displayText), hostIdentifier: identifier,
            privateKey: privateKey, publicKey: publicKey,
            peerPublicKey: values["tvpair_peer_public_key"] as? Data,
            peerIdentifier: values["tvpair_peer_identifier"] as? Data,
            alternateIRK: values["alt_irk"] as? Data, endpoint: endpoint)
        record.pairedAt = values["tvpair_paired_at"] as? Date; record.importedAt = Date()
        // Imported IDs cannot overwrite an existing credential.
        try record.validate(); return record
    }
    public var summary: SavedDevice {
        SavedDevice(id: id, name: deviceName, identifier: deviceIdentifier, productType: productType, pairedAt: pairedAt, importedAt: importedAt, endpoint: lastEndpoint, canVerifyPeer: peerPublicKey != nil && peerIdentifier != nil)
    }
}

public struct SavedDevice: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let identifier: String
    public let productType: String?
    public let pairedAt: Date?
    public let importedAt: Date?
    public let endpoint: ConnectionEndpoint?
    public let canVerifyPeer: Bool
}
