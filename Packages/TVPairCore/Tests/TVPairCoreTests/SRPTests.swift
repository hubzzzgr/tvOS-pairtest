import XCTest
@testable import TVPairCore

final class SRPTests: XCTestCase {
    func testIndependentClientServerVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "srp", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        func data(_ key: String) throws -> Data { try XCTUnwrap(fixture[key].flatMap(Data.init(hex:))) }
        let session = try SRPSession(pin: "123456", serverPublic: data("serverPublic"), salt: data("salt"), privateKey: data("privateKey"))
        XCTAssertEqual(session.publicKey, try data("publicKey")); XCTAssertEqual(session.key, try data("key"))
        XCTAssertEqual(session.proof, try data("proof")); XCTAssertTrue(session.verify(try data("serverProof")))
        XCTAssertFalse(session.verify(Data(repeating: 0, count: 64)))
        let wrong = try SRPSession(pin: "654321", serverPublic: data("serverPublic"), salt: data("salt"), privateKey: data("privateKey"))
        XCTAssertFalse(wrong.verify(try data("serverProof")))
    }
    func testRejectsInvalidPublicValuesAndPIN() {
        XCTAssertThrowsError(try SRPSession(pin: "123456", serverPublic: Data([0]), salt: Data([1])))
        XCTAssertThrowsError(try SRPSession(pin: "123456", serverPublic: SRPSession.prime.serialize(), salt: Data([1])))
        XCTAssertThrowsError(try SRPSession(pin: "12345x", serverPublic: Data([1]), salt: Data([1])))
    }
    func testResponderRoleMatchesIndependentServerVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "srp", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        func data(_ key: String) throws -> Data { try XCTUnwrap(fixture[key].flatMap(Data.init(hex:))) }
        let server = try SRPServerSession(pin: "123456", salt: data("salt"), privateKey: Data((1...128).reversed().map { UInt8($0) }))
        XCTAssertEqual(server.publicKey, try data("serverPublic"))
        let result = try server.process(clientPublic: data("publicKey"), clientProof: data("proof"))
        XCTAssertEqual(result.key, try data("key")); XCTAssertEqual(result.proof, try data("serverProof"))
        XCTAssertThrowsError(try server.process(clientPublic: data("publicKey"), clientProof: Data(repeating: 0, count: 64)))
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = [], index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<end], radix: 16) else { return nil }
            bytes.append(value); index = end
        }
        self = Data(bytes)
    }
}
