import Foundation
import Network
import Darwin

/// Targeted DNS-SD using a direct UDP query to the selected device, not a
/// NetServiceBrowser or a multicast socket. RFC 6762 sections 5.5 and 6.7.
/// Answers are endpoint hints only; RPPairing must authenticate the peer.
public final class DirectPairingProbe: @unchecked Sendable {
    private let connection: NWConnection
    private let host: String
    private let queue = DispatchQueue(label: "TVPair.direct-dns")
    private let lock = NSLock()
    private var used = false
    public init(host: String) throws {
        let endpoint = try ConnectionEndpoint(host: host, port: "5353")
        let literal = String(endpoint.host.split(separator: "%")[0])
        var v4 = in_addr(), v6 = in6_addr()
        let ipv4 = inet_pton(AF_INET, literal, &v4) == 1
        let ipv6 = inet_pton(AF_INET6, literal, &v6) == 1
        guard ipv4 || ipv6 else { throw TVPairError.unsupported("enter the Apple TV's numeric IP address for direct developer setup") }
        if ipv4 {
            let first = UInt8(truncatingIfNeeded: v4.s_addr)
            guard first != 0, first != 127, first < 224 else { throw TVPairError.invalidEndpoint }
        } else {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            guard bytes[0] != 0xff, bytes.contains(where: { $0 != 0 }), bytes != Array(repeating: 0, count: 15) + [1] else { throw TVPairError.invalidEndpoint }
        }
        self.host = endpoint.host
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: 5353, using: .udp)
    }
    public func cancel() { connection.cancel() }
    private func begin() throws {
        lock.lock(); defer { lock.unlock() }
        guard !used else { throw TVPairError.malformed("direct lookup requires a fresh probe") }
        used = true
    }
    private func execute<T>(timeout: TimeInterval, start: @escaping (OperationGate<T>) -> Void) async throws -> T {
        let gate = OperationGate<T>()
        let timer = DispatchWorkItem { [weak self] in gate.finish(.failure(TVPairError.timeout)); self?.cancel() }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                queue.async { if !gate.finished { start(gate) } }
                queue.asyncAfter(deadline: .now() + max(0.001, timeout), execute: timer)
            }
        } onCancel: { [weak self] in gate.finish(.failure(CancellationError())); self?.cancel() }
    }
    /// One operation per probe. Queries only the chosen IP on UDP 5353.
    public func resolve(_ service: ServiceKind) async throws -> ConnectionEndpoint {
        guard service.supportsPairing else { throw TVPairError.unsupported("direct lookup supports pairing services only") }
        try begin()
        defer { cancel() }
        try await execute(timeout: 3) { [self] (gate: OperationGate<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case let .failed(error): gate.finish(.failure(TCPTransport.safeError(error)))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        let name = service.rawValue + "local.", serviceName = DNSName(service.rawValue + "local.")
        var records = try await query(name, type: 12)
        let instances = Set(records.compactMap { record -> DNSName? in
            guard record.name == serviceName, record.ttl > 0, case let .pointer(instance) = record.value,
                  instance.labels.count == serviceName.labels.count + 1,
                  instance.labels.dropFirst().map({ $0.lowercased() }) == serviceName.labels.map({ $0.lowercased() }) else { return nil }
            return instance
        })
        guard !instances.isEmpty, instances.count <= 4 else {
            throw TVPairError.unsupported("the selected device did not advertise the requested developer pairing service in its direct DNS response. Keep Remote App and Devices open on the TV")
        }
        for instance in instances where !records.contains(where: { $0.name == instance && $0.type == 33 && $0.ttl > 0 }) {
            records += try await query(instance, type: 33)
        }
        let ports = Set(records.compactMap { record -> UInt16? in
            guard instances.contains(record.name), record.ttl > 0,
                  case let .service(port, target) = record.value,
                  target.labels.last?.lowercased() == "local", port > 0 else { return nil }
            return port
        })
        guard ports.count == 1, let port = ports.first else {
            throw TVPairError.unsupported("the selected device returned no unique pairing port. No pairing request was sent")
        }
        // Dial the selected numeric IP, never an answer-supplied address. A
        // responder cannot redirect the next connection to another host.
        return try ConnectionEndpoint(host: host, port: String(port))
    }
    private func query(_ name: String, type: UInt16) async throws -> [DNSRecord] { try await query(DNSName(name), type: type) }
    private func query(_ name: DNSName, type: UInt16) async throws -> [DNSRecord] {
        let id = UInt16.random(in: 1...UInt16.max)
        let bytes = try DirectDNSCodec.query(name, type: type, id: id)
        try await execute(timeout: 2) { [self] (gate: OperationGate<Void>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { gate.finish(.failure(TCPTransport.safeError(error))) } else { gate.finish(.success(())) }
            })
        }
        let deadline = Date().addingTimeInterval(4)
        for _ in 0..<8 {
            let data: Data = try await execute(timeout: deadline.timeIntervalSinceNow) { [self] gate in
                connection.receiveMessage { data, _, _, error in
                    if let error { gate.finish(.failure(TCPTransport.safeError(error))) }
                    else if let data { gate.finish(.success(data.zeroBased)) }
                    else { gate.finish(.failure(TVPairError.closed)) }
                }
            }
            if let records = try DirectDNSCodec.response(data, id: id) { return records }
            guard deadline.timeIntervalSinceNow > 0 else { throw TVPairError.timeout }
        }
        throw TVPairError.malformed("direct DNS reply limit")
    }
}

/// Labels are kept separate: a DNS-SD instance label can itself contain dots.
struct DNSName: Hashable, Sendable {
    let labels: [String]
    init(_ value: String) { labels = value.split(separator: ".").map(String.init) }
    init(labels: [String]) { self.labels = labels }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.labels.map { $0.lowercased() } == rhs.labels.map { $0.lowercased() } }
    func hash(into hasher: inout Hasher) { hasher.combine(labels.map { $0.lowercased() }) }
}
struct DNSRecord: Sendable {
    enum Value: Sendable { case pointer(DNSName), service(UInt16, DNSName), other }
    let name: DNSName, type: UInt16, ttl: UInt32, value: Value
}
enum DirectDNSCodec {
    private static func be(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 255)]) }
    static func query(_ name: DNSName, type: UInt16, id: UInt16) throws -> Data {
        var result = be(id) + be(0) + be(1) + Data(repeating: 0, count: 6)
        var size = 1
        for label in name.labels {
            let bytes = Data(label.utf8)
            guard (1...63).contains(bytes.count), size + bytes.count + 1 <= 255 else { throw TVPairError.malformed("direct DNS query name") }
            size += bytes.count + 1; result.append(UInt8(bytes.count)); result += bytes
        }
        return result + Data([0]) + be(type) + be(1)
    }
    /// nil ignores another transaction; all structural failures are bounded.
    static func response(_ data: Data, id: UInt16) throws -> [DNSRecord]? {
        let b = data.zeroBased
        guard b.count >= 12, b.count <= 65_535 else { throw TVPairError.malformed("direct DNS packet size") }
        func u16(_ p: Int) -> UInt16 { UInt16(b[p]) << 8 | UInt16(b[p + 1]) }
        guard u16(0) == id else { return nil }
        let flags = u16(2)
        guard flags & 0x8000 != 0, flags & 0x780f == 0, flags & 0x0200 == 0 else { throw TVPairError.unsupported("direct DNS negative or truncated response") }
        let questions = Int(u16(4)), count = Int(u16(6)) + Int(u16(8)) + Int(u16(10))
        guard questions <= 16, count <= 128 else { throw TVPairError.malformed("direct DNS record count") }
        var p = 12, records: [DNSRecord] = []
        for _ in 0..<questions {
            _ = try name(b, position: &p)
            guard p + 4 <= b.count else { throw TVPairError.malformed("direct DNS question") }; p += 4
        }
        for _ in 0..<count {
            let owner = try name(b, position: &p)
            guard p + 10 <= b.count else { throw TVPairError.malformed("direct DNS record header") }
            let type = u16(p), cls = u16(p + 2) & 0x7fff
            let ttl = UInt32(u16(p + 4)) << 16 | UInt32(u16(p + 6)), size = Int(u16(p + 8)); p += 10
            guard size <= b.count - p else { throw TVPairError.malformed("direct DNS record boundary") }
            let end = p + size
            var value = DNSRecord.Value.other
            if cls == 1 && type == 12 {
                value = .pointer(try name(b, position: &p))
                guard p == end else { throw TVPairError.malformed("direct DNS PTR boundary") }
            } else if cls == 1 && type == 33 {
                guard size >= 7 else { throw TVPairError.malformed("direct DNS SRV boundary") }
                let port = u16(p + 4); p += 6
                value = .service(port, try name(b, position: &p))
                guard p == end else { throw TVPairError.malformed("direct DNS SRV target boundary") }
            }
            if cls == 1 { records.append(DNSRecord(name: owner, type: type, ttl: ttl, value: value)) }
            p = end
        }
        guard p == b.count else { throw TVPairError.malformed("direct DNS trailing bytes") }
        return records
    }
    private static func name(_ b: Data, position: inout Int) throws -> DNSName {
        var p = position, labels: [String] = [], consumed: Int?, visited: Set<Int> = [], expanded = 1
        for _ in 0..<128 {
            guard p < b.count, visited.insert(p).inserted else { throw TVPairError.malformed("direct DNS name pointer") }
            let size = Int(b[p])
            if size & 0xc0 == 0xc0 {
                guard p + 1 < b.count else { throw TVPairError.malformed("direct DNS truncated pointer") }
                if consumed == nil { consumed = p + 2 }
                p = (size & 0x3f) << 8 | Int(b[p + 1]); continue
            }
            guard size & 0xc0 == 0, size <= 63 else { throw TVPairError.malformed("direct DNS label type") }
            p += 1
            if size == 0 { position = consumed ?? p; return DNSName(labels: labels) }
            guard size <= b.count - p, expanded + size + 1 <= 255,
                  let label = String(data: b.subdata(in: p..<(p + size)), encoding: .utf8) else { throw TVPairError.malformed("direct DNS label boundary") }
            labels.append(label); expanded += size + 1; p += size
        }
        throw TVPairError.malformed("direct DNS name depth")
    }
}
