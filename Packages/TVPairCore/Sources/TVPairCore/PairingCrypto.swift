import Foundation
import CryptoKit
import BigInt
import Security

enum PairingCrypto {
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw TVPairError.authentication }
        return Data(bytes)
    }
    static func hash(_ data: Data) -> Data { Data(SHA512.hash(data: data)) }
    static func derive(_ key: Data, salt: String = "", info: String) -> Data {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    static func nonce(_ label: String) -> Data { Data(repeating: 0, count: 4) + Data(label.utf8) }
    static func seal(_ data: Data, key: Data, nonce: Data) throws -> Data {
        let box = try ChaChaPoly.seal(data, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce))
        var result = Data(); result.append(box.ciphertext); result.append(box.tag)
        return result
    }
    static func open(_ data: Data, key: Data, nonce: Data) throws -> Data {
        guard data.count >= 16 else { throw TVPairError.authentication }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: data.dropLast(16), tag: data.suffix(16))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
        } catch { throw TVPairError.authentication }
    }
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// RFC 5054 3072-bit group, generator 5, SHA-512; Apple's Pair-Setup integer encoding.
/// BigInt is variable-time. This experimental client is not a hardened cryptographic library.
struct SRPSession {
    static let prime = BigUInt("""
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6\
    3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245\
    E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411\
    7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
    83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08\
    CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9\
    DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D\
    04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
    ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273\
    3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31\
    43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
    """, radix: 16)!
    let publicKey: Data
    let key: Data
    let proof: Data
    let expectedServerProof: Data

    static func bytes(_ value: BigUInt) -> Data { value == 0 ? Data([0]) : value.serialize() }
    static func padded(_ value: BigUInt) -> Data { Data(repeating: 0, count: max(0, 384 - bytes(value).count)) + bytes(value) }

    init(pin: String, serverPublic: Data, salt: Data, privateKey: Data? = nil) throws {
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }), !salt.isEmpty, salt.count <= 64, !serverPublic.isEmpty, serverPublic.count <= 384 else { throw TVPairError.malformed("SRP parameters") }
        let n = Self.prime, g = BigUInt(5)
        let a = BigUInt(try privateKey ?? PairingCrypto.random(128))
        let b = BigUInt(serverPublic)
        guard a > 0, b > 0, b < n else { throw TVPairError.authentication }
        let clientPublic = g.power(a, modulus: n)
        let k = BigUInt(PairingCrypto.hash(Self.bytes(n) + Self.padded(g)))
        let u = BigUInt(PairingCrypto.hash(Self.padded(clientPublic) + Self.padded(b)))
        guard u != 0 else { throw TVPairError.authentication }
        let x = BigUInt(PairingCrypto.hash(salt + PairingCrypto.hash(Data("Pair-Setup:\(pin)".utf8))))
        let subtract = (k * g.power(x, modulus: n)) % n
        let base = (b + n - subtract) % n
        guard base != 0 else { throw TVPairError.authentication }
        let shared = base.power(a + u * x, modulus: n)
        let key = PairingCrypto.hash(Self.bytes(shared))
        let groupHash = BigUInt(PairingCrypto.hash(Self.bytes(n))) ^ BigUInt(PairingCrypto.hash(Self.bytes(g)))
        let proof = PairingCrypto.hash(Self.bytes(groupHash) + Self.bytes(BigUInt(PairingCrypto.hash(Data("Pair-Setup".utf8)))) + salt + Self.bytes(clientPublic) + Self.bytes(b) + key)
        publicKey = Self.bytes(clientPublic); self.key = key; self.proof = proof
        expectedServerProof = PairingCrypto.hash(publicKey + proof + key)
    }
    func verify(_ proof: Data) -> Bool { PairingCrypto.equal(expectedServerProof, proof) }
}

/// Accessory/server SRP role for device-initiated iOS 27 pairing.
struct SRPServerSession {
    let salt: Data
    let publicKey: Data
    private let privateKey: BigUInt
    private let verifier: BigUInt
    init(pin: String, salt: Data? = nil, privateKey: Data? = nil) throws {
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw TVPairError.authentication }
        let salt = try salt ?? PairingCrypto.random(16)
        guard salt.count == 16 else { throw TVPairError.malformed("SRP server salt") }
        self.salt = salt
        let n = SRPSession.prime, g = BigUInt(5)
        let x = BigUInt(PairingCrypto.hash(salt + PairingCrypto.hash(Data("Pair-Setup:\(pin)".utf8))))
        verifier = g.power(x, modulus: n)
        let k = BigUInt(PairingCrypto.hash(SRPSession.bytes(n) + SRPSession.padded(g)))
        var selected: (BigUInt, Data)?
        for _ in 0..<32 {
            let secret = BigUInt(try privateKey ?? PairingCrypto.random(32))
            guard secret > 0 else { throw TVPairError.authentication }
            let publicValue = SRPSession.bytes((k * verifier + g.power(secret, modulus: n)) % n)
            if publicValue.count == 384 { selected = (secret, publicValue); break }
            if privateKey != nil { break }
        }
        guard let selected else { throw TVPairError.authentication }
        self.privateKey = selected.0; publicKey = selected.1
    }
    func process(clientPublic: Data, clientProof: Data) throws -> (key: Data, proof: Data) {
        let n = SRPSession.prime, a = BigUInt(clientPublic), b = BigUInt(publicKey)
        guard !clientPublic.isEmpty, clientPublic.count <= 384, a > 0, a < n, clientProof.count == 64 else { throw TVPairError.authentication }
        let u = BigUInt(PairingCrypto.hash(SRPSession.padded(a) + SRPSession.padded(b)))
        guard u != 0 else { throw TVPairError.authentication }
        let shared = (a * verifier.power(u, modulus: n)).power(privateKey, modulus: n)
        let key = PairingCrypto.hash(SRPSession.bytes(shared))
        let group = BigUInt(PairingCrypto.hash(SRPSession.bytes(n))) ^ BigUInt(PairingCrypto.hash(Data([5])))
        let proof = PairingCrypto.hash(SRPSession.bytes(group) + SRPSession.bytes(BigUInt(PairingCrypto.hash(Data("Pair-Setup".utf8)))) + salt + SRPSession.bytes(a) + SRPSession.bytes(b) + key)
        guard PairingCrypto.equal(clientProof, proof) else { throw TVPairError.authentication }
        return (key, PairingCrypto.hash(SRPSession.bytes(a) + proof + key))
    }
}

public enum TLV8 {
    public static func encode(_ entries: [(UInt8, Data)]) -> Data {
        var output = Data()
        for (tag, value) in entries {
            let data = value.zeroBased
            if data.isEmpty { output.append(contentsOf: [tag, 0]); continue }
            var index = 0
            while index < data.count {
                let length = min(255, data.count - index)
                output.append(contentsOf: [tag, UInt8(length)]); output.append(data.subdata(in: index..<(index + length)))
                index += length
            }
        }
        return output
    }
    public static func decode(_ value: Data) throws -> [UInt8: Data] {
        let data = value.zeroBased
        var result: [UInt8: Data] = [:], offset = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { throw TVPairError.malformed("truncated TLV header") }
            let tag = data[offset], length = Int(data[offset + 1]); offset += 2
            guard offset + length <= data.count else { throw TVPairError.malformed("truncated TLV value") }
            result[tag, default: Data()].append(data.subdata(in: offset..<(offset + length))); offset += length
        }
        return result
    }
    static func require(_ values: [UInt8: Data], _ tag: UInt8, size: Int? = nil) throws -> Data {
        guard let data = values[tag], !data.isEmpty, size == nil || data.count == size else { throw TVPairError.malformed("missing or invalid TLV component") }
        return data
    }
    static func check(_ values: [UInt8: Data], state: UInt8) throws {
        if let error = values[7]?.first {
            let retry = values[8].flatMap { data -> Int? in
                guard data.count <= 4 else { return nil }
                return data.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            }
            throw TVPairError.rejected(Int(error), retry)
        }
        guard values[6] == Data([state]) else { throw TVPairError.malformed("unexpected TLV state") }
    }
}

extension Data {
    /// CryptoKit's ciphertext and Foundation Data slices may retain a nonzero index.
    /// A raw-buffer copy deliberately establishes zero-based parser offsets.
    var zeroBased: Data { withUnsafeBytes { Data($0) } }
}
