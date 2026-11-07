import Foundation
import TVPairTLS

/// TLS 1.2 PSK over the existing public TCP transport. OpenSSL owns the TLS
/// protocol, record authentication, Finished proofs, and cipher implementation.
/// Memory BIOs let bounded, cancellable NWConnection I/O remain in Swift.
public actor PSKTLSTransport: ByteTransport {
    private nonisolated let upstream: any ByteTransport
    private let engine: OpaquePointer
    private var connected = false
    private var operating = false
    private var terminal = false
    public private(set) var negotiatedCipher: UInt16?

    public init(upstream: any ByteTransport, preSharedKey: Data) throws {
        guard let engine = preSharedKey.withUnsafeBytes({
            tvp_tls_create($0.bindMemory(to: UInt8.self).baseAddress, $0.count)
        }) else { throw TVPairError.unsupported("could not initialize the bundled TLS 1.2 PSK engine") }
        self.engine = engine; self.upstream = upstream
    }
    public nonisolated func cancel() { upstream.cancel() }
    deinit { tvp_tls_free(engine); upstream.cancel() }

    private func begin() throws {
        try Task.checkCancellation()
        guard !terminal else { throw TVPairError.closed }
        guard !operating else { throw TVPairError.malformed("concurrent TLS operation") }
        operating = true
    }
    private func remaining(_ deadline: Date) throws -> TimeInterval {
        try Task.checkCancellation()
        let value = deadline.timeIntervalSinceNow
        guard value > 0 else { throw TVPairError.timeout }
        return value
    }
    private func check(_ result: Int32) throws {
        if result == TVP_TLS_CLOSED { throw TVPairError.closed }
        if result < 0 { throw TVPairError.network("OpenSSL", tvp_tls_error(engine)) }
    }
    private func flush(deadline: Date) async throws {
        var total = 0
        while true {
            var data = Data(count: 16384)
            let count = data.withUnsafeMutableBytes { tvp_tls_drain(engine, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            guard count >= 0 else { throw TVPairError.network("OpenSSL", tvp_tls_error(engine)) }
            if count == 0 { return }
            total += Int(count)
            guard total <= 1_048_576 else { throw TVPairError.malformed("TLS output limit") }
            try await upstream.send(data.prefix(Int(count)).zeroBased, timeout: remaining(deadline))
        }
    }
    private func receiveRecord(deadline: Date) async throws {
        let header = try await upstream.readExactly(5, timeout: remaining(deadline)).zeroBased
        let count = Int(header[3]) << 8 | Int(header[4])
        guard (20...23).contains(header[0]), header[1] == 3, count <= 18432 else { throw TVPairError.malformed("TLS record header or length") }
        let body = try await upstream.readExactly(count, timeout: remaining(deadline))
        let record = header + body
        let result = record.withUnsafeBytes { tvp_tls_feed(engine, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        try check(result)
    }
    public func connect(timeout: TimeInterval = 12) async throws {
        try begin(); defer { operating = false }
        do {
            guard !connected else { throw TVPairError.malformed("TLS session already connected") }
            let deadline = Date().addingTimeInterval(timeout)
            try await upstream.connect(timeout: remaining(deadline))
            for _ in 0..<64 {
                let result = tvp_tls_handshake(engine)
                try check(result)
                try await flush(deadline: deadline)
                if result == TVP_TLS_DONE {
                    negotiatedCipher = tvp_tls_cipher(engine); connected = true; return
                }
                try await receiveRecord(deadline: deadline)
            }
            throw TVPairError.malformed("TLS handshake record limit")
        } catch { terminal = true; upstream.cancel(); throw error }
    }
    public func send(_ data: Data, timeout: TimeInterval = 10) async throws {
        try begin(); defer { operating = false }
        do {
            guard connected else { throw TVPairError.authentication }
            guard data.count <= 1_048_576 else { throw TVPairError.malformed("TLS write limit") }
            let deadline = Date().addingTimeInterval(timeout)
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + 16384, data.count))
                var complete = false
                for _ in 0..<64 {
                    _ = try remaining(deadline)
                    var written = 0
                    let result = chunk.withUnsafeBytes { tvp_tls_write(engine, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &written) }
                    try check(result); try await flush(deadline: deadline)
                    if result == TVP_TLS_DONE {
                        guard written > 0 && written <= chunk.count else { throw TVPairError.malformed("TLS write progress") }
                        offset += written; complete = true; break
                    }
                    try await receiveRecord(deadline: deadline)
                }
                guard complete else { throw TVPairError.malformed("TLS write record limit") }
            }
        } catch { terminal = true; upstream.cancel(); throw error }
    }
    public func readExactly(_ count: Int, timeout: TimeInterval = 10) async throws -> Data {
        try begin(); defer { operating = false }
        do {
            guard connected else { throw TVPairError.authentication }
            guard count >= 0 && count <= 1_048_576 else { throw TVPairError.malformed("TLS read limit") }
            let deadline = Date().addingTimeInterval(timeout)
            var output = Data(), records = 0
            while output.count < count {
                _ = try remaining(deadline)
                var data = Data(count: min(16384, count - output.count)), received = 0
                let result = data.withUnsafeMutableBytes { tvp_tls_read(engine, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &received) }
                try check(result); try await flush(deadline: deadline)
                if result == TVP_TLS_DONE {
                    guard received > 0 && received <= data.count else { throw TVPairError.malformed("TLS read progress") }
                    output.append(data.prefix(received))
                } else {
                    records += 1
                    guard records <= 4096 else { throw TVPairError.malformed("TLS read record limit") }
                    try await receiveRecord(deadline: deadline)
                }
            }
            return output
        } catch { terminal = true; upstream.cancel(); throw error }
    }
}
