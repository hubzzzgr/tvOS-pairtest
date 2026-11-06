import Foundation
import Darwin

public struct TunnelConfiguration: Sendable {
    public let clientAddress: String
    public let serverAddress: String
    public let rsdPort: UInt16
    public let mtu: Int
}

public struct TrustedTunnel: Sendable {
    public let transport: any ByteTransport
    public let configuration: TunnelConfiguration
    public static func establish(endpoint: ConnectionEndpoint, session: RemotePairingClient) async throws -> TrustedTunnel {
        let listener = try await session.createTunnelListener()
        let target = try ConnectionEndpoint(host: endpoint.host, port: String(listener.port))
        let transport = TCPTransport(endpoint: target, preSharedKey: listener.key)
        do {
            try await transport.connect(timeout: 12)
            try await transport.send(FramedJSON.encode(["type": "clientHandshakeRequest", "mtu": 16000], magic: "CDTunnel"), timeout: 10)
            let response = try await FramedJSON.receive(from: transport, magic: "CDTunnel")
            guard response["type"] as? String == "serverHandshakeResponse",
                  let client = nested(response, "clientParameters", "address") as? String,
                  let server = response["serverAddress"] as? String,
                  let port = response["serverRSDPort"] as? Int, let validPort = UInt16(exactly: port), validPort > 0,
                  let mtu = nested(response, "clientParameters", "mtu") as? Int, (1280...65535).contains(mtu),
                  IPv6TCPPacket.address(client) != nil, IPv6TCPPacket.address(server) != nil else { throw TVPairError.malformed("CDTunnel handshake configuration") }
            return TrustedTunnel(transport: transport, configuration: TunnelConfiguration(clientAddress: client, serverAddress: server, rsdPort: validPort, mtu: mtu))
        } catch { transport.cancel(); throw error }
    }
}

/// A deliberately bounded single-stream TCP client over CDTunnel's reliable IPv6 byte stream.
/// No TUN interface, kernel routes, VPN, entitlement, raw socket, or packet injection on the LAN.
/// It supports unfragmented IPv6/TCP, MSS negotiation, checksums, ACKs, duplicate segments and FIN.
/// Unsupported extensions and flow-control stalls fail explicitly. This is a diagnostic transport.
public final class TunnelTCPTransport: ByteTransport, @unchecked Sendable {
    private let upstream: any ByteTransport
    private let stream: TunnelTCPStream
    public init(tunnel: TrustedTunnel, port: UInt16? = nil) throws {
        upstream = tunnel.transport
        stream = try TunnelTCPStream(upstream: tunnel.transport, configuration: tunnel.configuration, port: port ?? tunnel.configuration.rsdPort)
    }
    public func connect(timeout: TimeInterval) async throws { try await stream.connect(timeout: timeout) }
    public func send(_ data: Data, timeout: TimeInterval) async throws { try await stream.send(data, timeout: timeout) }
    public func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await stream.readExactly(count, timeout: timeout) }
    public func cancel() { upstream.cancel() }
}

actor TunnelTCPStream {
    let upstream: any ByteTransport
    let source: Data
    let destination: Data
    let sourcePort: UInt16
    let destinationPort: UInt16
    var sequence: UInt32
    var acknowledgement: UInt32 = 0
    var window: UInt16 = 65535
    var buffer = Data()
    var connected = false
    var ended = false

    init(upstream: any ByteTransport, configuration: TunnelConfiguration, port: UInt16) throws {
        guard let source = IPv6TCPPacket.address(configuration.clientAddress), let destination = IPv6TCPPacket.address(configuration.serverAddress), port > 0 else { throw TVPairError.invalidEndpoint }
        self.upstream = upstream; self.source = source; self.destination = destination
        sourcePort = UInt16.random(in: 49152...65535); destinationPort = port; sequence = UInt32.random(in: 0...UInt32.max)
    }
    func emit(flags: UInt8, payload: Data = Data()) async throws {
        let packet = IPv6TCPPacket.make(source: source, destination: destination, sourcePort: sourcePort, destinationPort: destinationPort, sequence: sequence, acknowledgement: acknowledgement, flags: flags, payload: payload)
        try await upstream.send(packet, timeout: 10)
    }
    func receive(deadline: Date) async throws -> IPv6TCPPacket.Segment {
        for _ in 0..<128 {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw TVPairError.timeout }
            let header = try await upstream.readExactly(40, timeout: deadline.timeIntervalSinceNow)
            guard header[0] >> 4 == 6 else { throw TVPairError.malformed("CDTunnel IPv6 version") }
            let size = Int(header[4]) << 8 | Int(header[5])
            guard size > 0 && size <= 65535 else { throw TVPairError.malformed("IPv6 payload length") }
            let payload = try await upstream.readExactly(size, timeout: max(0.001, deadline.timeIntervalSinceNow))
            // ICMPv6 and packets for other connections may share the tunnel.
            guard header.subdata(in: 8..<24) == destination, header.subdata(in: 24..<40) == source else { continue }
            guard header[6] == 6 else {
                if header[6] == 58 { continue }
                throw TVPairError.unsupported("IPv6 extension headers on the diagnostic TCP stream")
            }
            let segment = try IPv6TCPPacket.parse(header + payload)
            guard segment.sourcePort == destinationPort, segment.destinationPort == sourcePort else { continue }
            if segment.flags & 4 != 0 { throw TVPairError.closed }
            window = segment.window
            return segment
        }
        throw TVPairError.malformed("too many unrelated tunnel packets")
    }
    func connect(timeout: TimeInterval) async throws {
        guard !connected else { throw TVPairError.malformed("TCP stream already connected") }
        let deadline = Date().addingTimeInterval(timeout), expected = sequence &+ 1
        try await emit(flags: 2)
        let segment = try await receive(deadline: deadline)
        guard segment.flags & 0x12 == 0x12, segment.acknowledgement == expected, segment.payload.isEmpty else { throw TVPairError.malformed("TCP SYN acknowledgement") }
        sequence = expected; acknowledgement = segment.sequence &+ 1; connected = true
        try await emit(flags: 0x10)
    }
    func consume(_ segment: IPv6TCPPacket.Segment) async throws {
        let hasFin = segment.flags & 1 != 0
        if !segment.payload.isEmpty || hasFin {
            if segment.sequence == acknowledgement {
                guard buffer.count + segment.payload.count <= 1_048_576 else { throw TVPairError.malformed("TCP receive buffer limit") }
                buffer.append(segment.payload); acknowledgement &+= UInt32(segment.payload.count)
                if hasFin { acknowledgement &+= 1; ended = true }
            }
            // Duplicate/out-of-order payload is not delivered; cumulative ACK asks for expected bytes.
            try await emit(flags: 0x10)
        }
    }
    func send(_ data: Data, timeout: TimeInterval) async throws {
        guard connected && !ended else { throw TVPairError.closed }
        guard data.count <= 65535 else { throw TVPairError.malformed("diagnostic TCP write limit") }
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        while offset < data.count {
            guard window > 0 else { throw TVPairError.unsupported("zero TCP send window") }
            let size = min(1024, Int(window), data.count - offset), original = sequence, expected = sequence &+ UInt32(size)
            try await emit(flags: 0x18, payload: data.subdata(in: offset..<(offset + size)))
            sequence = expected
            // Reliable ordered TLS carrier: bounded wait for the peer's cumulative acknowledgement.
            var acknowledged = false
            for _ in 0..<256 {
                let segment = try await receive(deadline: deadline)
                try await consume(segment)
                if segment.flags & 0x10 != 0 && segment.acknowledgement == expected { acknowledged = true; break }
                if segment.flags & 0x10 != 0 && segment.acknowledgement &- original > UInt32(size) { throw TVPairError.malformed("TCP acknowledgement outside send range") }
            }
            guard acknowledged else { throw TVPairError.timeout }
            sequence = expected; offset += size
        }
    }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        guard connected, count >= 0, count <= 1_048_576 else { throw TVPairError.malformed("diagnostic TCP read") }
        let deadline = Date().addingTimeInterval(timeout)
        var packets = 0
        while buffer.count < count {
            if ended { throw TVPairError.closed }
            guard packets < 4096 else { throw TVPairError.malformed("TCP packet limit") }
            try await consume(receive(deadline: deadline)); packets += 1
        }
        let output = buffer.prefix(count).zeroBased; buffer.removeFirst(count); return output
    }
}

enum IPv6TCPPacket {
    struct Segment {
        let sourcePort: UInt16, destinationPort: UInt16
        let sequence: UInt32, acknowledgement: UInt32
        let flags: UInt8, window: UInt16
        let payload: Data
    }
    static func address(_ text: String) -> Data? {
        var value = in6_addr()
        guard inet_pton(AF_INET6, text, &value) == 1 else { return nil }
        return withUnsafeBytes(of: value) { Data($0) }
    }
    static func be(_ value: UInt32, count: Int = 4) -> Data { Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func number(_ data: Data, _ offset: Int, count: Int) -> UInt32 { data.subdata(in: offset..<(offset + count)).reduce(0) { $0 << 8 | UInt32($1) } }
    static func checksum(_ data: Data) -> UInt16 {
        let bytes = Array(data); var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) { sum += UInt32(bytes[i]) << 8 | (i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0) }
        while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
        return ~UInt16(sum)
    }
    static func make(source: Data, destination: Data, sourcePort: UInt16, destinationPort: UInt16, sequence: UInt32, acknowledgement: UInt32, flags: UInt8, payload: Data) -> Data {
        let syn = flags & 2 != 0
        var tcp = be(UInt32(sourcePort), count: 2) + be(UInt32(destinationPort), count: 2) + be(sequence) + be(acknowledgement)
        tcp += Data([syn ? 0x60 : 0x50, flags, 0xff, 0xff, 0, 0, 0, 0])
        if syn { tcp += Data([2, 4, 4, 0xc4]) } // MSS 1220, fits IPv6 minimum MTU.
        tcp += payload
        let pseudo = source + destination + be(UInt32(tcp.count)) + Data([0, 0, 0, 6])
        let value = checksum(pseudo + tcp); tcp[16] = UInt8(value >> 8); tcp[17] = UInt8(value & 255)
        return Data([0x60, 0, 0, 0]) + be(UInt32(tcp.count), count: 2) + Data([6, 64]) + source + destination + tcp
    }
    static func parse(_ value: Data) throws -> Segment {
        let packet = value.zeroBased
        guard packet.count >= 60, packet[0] >> 4 == 6, packet[6] == 6 else { throw TVPairError.malformed("IPv6 TCP packet") }
        let tcp = packet.subdata(in: 40..<packet.count), headerSize = Int(tcp[12] >> 4) * 4
        guard headerSize >= 20, headerSize <= tcp.count,
              Int(number(packet, 4, count: 2)) == tcp.count,
              checksum(packet.subdata(in: 8..<40) + be(UInt32(tcp.count)) + Data([0, 0, 0, 6]) + tcp) == 0 else { throw TVPairError.malformed("TCP length or checksum") }
        return Segment(sourcePort: UInt16(number(tcp, 0, count: 2)), destinationPort: UInt16(number(tcp, 2, count: 2)), sequence: number(tcp, 4, count: 4), acknowledgement: number(tcp, 8, count: 4), flags: tcp[13], window: UInt16(number(tcp, 14, count: 2)), payload: tcp.subdata(in: headerSize..<tcp.count))
    }
}
