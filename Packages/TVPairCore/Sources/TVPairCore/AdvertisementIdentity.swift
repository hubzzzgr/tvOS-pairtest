import Foundation

/// Remote Pairing's mDNS identity hint. Full Pair-Verify is still mandatory.
public enum AdvertisementIdentity {
    public static func matches(record: PairingRecord, identifier: String?, authTag: String?) -> Bool {
        guard let key = record.alternateIRK, key.count == 16, let identifier, identifier.utf8.count <= 256,
              let authTag, let expected = Data(base64Encoded: authTag), expected.count == 6 else { return false }
        return PairingCrypto.equal(tag(key: key, identifier: identifier), expected)
    }
    static func tag(key: Data, identifier: String) -> Data {
        precondition(key.count == 16)
        func rotate(_ value: UInt64, _ shift: UInt64) -> UInt64 { value << shift | value >> (64 - shift) }
        func integer(_ data: Data) -> UInt64 { data.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        let k0 = integer(Data(key.prefix(8))), k1 = integer(Data(key.suffix(8)))
        var a = UInt64(0x736f6d6570736575) ^ k0, b = UInt64(0x646f72616e646f6d) ^ k1
        var c = UInt64(0x6c7967656e657261) ^ k0, d = UInt64(0x7465646279746573) ^ k1
        func round() {
            a &+= b; b = rotate(b, 13); b ^= a; a = rotate(a, 32)
            c &+= d; d = rotate(d, 16); d ^= c
            a &+= d; d = rotate(d, 21); d ^= a
            c &+= b; b = rotate(b, 17); b ^= c; c = rotate(c, 32)
        }
        let bytes = Data(identifier.utf8); var offset = 0
        while offset + 8 <= bytes.count {
            let word = integer(bytes.subdata(in: offset..<(offset + 8)))
            d ^= word; round(); round(); a ^= word; offset += 8
        }
        let last = UInt64(bytes.count & 255) << 56 | integer(bytes.subdata(in: offset..<bytes.count))
        d ^= last; round(); round(); a ^= last; c ^= 255
        for _ in 0..<4 { round() }
        let value = a ^ b ^ c ^ d
        return Data((0..<6).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}
