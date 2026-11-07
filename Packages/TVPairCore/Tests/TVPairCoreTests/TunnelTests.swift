import XCTest
@testable import TVPairCore

final class TunnelTests: XCTestCase {
    func testInterleavedRSDDataIsBufferedWhileOpeningDeveloperStream() async throws {
        let carrier = TunnelPeerTransport()
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let rsd = try TunnelTCPTransport(tunnel: tunnel)
        try await rsd.connect(timeout: 1)
        await carrier.interleaveOldPayload()
        let developer = try TunnelTCPTransport(tunnel: tunnel, port: 4321)
        try await developer.connect(timeout: 1)
        let old = try await rsd.readExactly(5, timeout: 1)
        XCTAssertEqual(old, Data("later".utf8), "Opening another port must not discard RSD data")
    }
    func testUserspaceHandshakeDataAcknowledgementsAndRead() async throws {
        let carrier = TunnelPeerTransport()
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let stream = try TunnelTCPTransport(tunnel: tunnel)
        try await stream.connect(timeout: 1)
        try await stream.send(Data("hello".utf8), timeout: 1)
        let response = try await stream.readExactly(5, timeout: 1)
        XCTAssertEqual(response, Data("world".utf8))
        let payload = await carrier.received()
        XCTAssertEqual(payload, Data("hello".utf8))
    }
    func testUserspaceRejectsCorruptedEncapsulatedPacket() async throws {
        let carrier = TunnelPeerTransport(corrupt: true)
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        do { try await TunnelTCPTransport(tunnel: tunnel).connect(timeout: 1); XCTFail("Invalid packet must fail") }
        catch { XCTAssertEqual(error as? TVPairError, .malformed("TCP length or checksum")) }
    }
}

private final class TunnelPeerTransport: ByteTransport, @unchecked Sendable {
    let peer: TunnelPeer
    init(corrupt: Bool = false) { peer = TunnelPeer(corrupt: corrupt) }
    func received() async -> Data { await peer.received }
    func interleaveOldPayload() async { await peer.armInterleaving() }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ data: Data, timeout: TimeInterval) async throws { try await peer.respond(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}
private actor TunnelPeer {
    let corrupt: Bool
    var output = Data(), received = Data()
    var sequence: UInt32 = 101
    var firstSYN: Data?
    var interleave = false
    func armInterleaving() { interleave = true }
    init(corrupt: Bool) { self.corrupt = corrupt }
    func take(_ count: Int) throws -> Data {
        guard output.count >= count else { throw TVPairError.closed }
        let data = Data(output.prefix(count)); output.removeFirst(count); return data
    }
    func respond(_ packet: Data) throws {
        let segment = try IPv6TCPPacket.parse(packet)
        let syn = segment.flags & 2 != 0
        if syn && interleave, let firstSYN {
            let first = try IPv6TCPPacket.parse(firstSYN)
            output += IPv6TCPPacket.make(source: firstSYN.subdata(in: 24..<40), destination: firstSYN.subdata(in: 8..<24), sourcePort: first.destinationPort, destinationPort: first.sourcePort, sequence: 101, acknowledgement: first.sequence &+ 1, flags: 0x18, payload: Data("later".utf8))
            interleave = false
        }
        if syn && firstSYN == nil { firstSYN = packet.zeroBased }
        guard syn || !segment.payload.isEmpty else { return }
        received.append(segment.payload)
        let payload = syn ? Data() : Data("world".utf8)
        var response = IPv6TCPPacket.make(source: packet.subdata(in: 24..<40), destination: packet.subdata(in: 8..<24), sourcePort: segment.destinationPort, destinationPort: segment.sourcePort, sequence: syn ? 100 : sequence, acknowledgement: segment.sequence &+ UInt32(syn ? 1 : segment.payload.count), flags: syn ? 0x12 : 0x18, payload: payload)
        if corrupt { response[56] ^= 1 }
        output.append(response); sequence &+= UInt32(payload.count)
    }
}
