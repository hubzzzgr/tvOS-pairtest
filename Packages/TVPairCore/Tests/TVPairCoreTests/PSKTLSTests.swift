import XCTest
@testable import TVPairCore

/// The server is a separate OpenSSL command-line program, not the memory-BIO
/// adapter being tested. All keys and payloads here are synthetic test data.
final class PSKTLSTests: XCTestCase {
    private let key = Data(repeating: 0x41, count: 32)
    func testAES256SHA384HandshakeAndEncryptedRoundTrip() async throws {
        try await roundTrip(cipher: "PSK-AES256-CBC-SHA384", code: 0x00af)
    }
    func testAES128SHAHandshakeAndEncryptedRoundTrip() async throws {
        try await roundTrip(cipher: "PSK-AES128-CBC-SHA", code: 0x008c)
    }
    private func roundTrip(cipher: String, code: UInt16) async throws {
        let server = try OpenSSLTestServer(cipher: cipher); defer { server.stop() }
        let port = try await server.start()
        let raw = TCPTransport(endpoint: try ConnectionEndpoint(host: "127.0.0.1", port: String(port)))
        let tls = try PSKTLSTransport(upstream: raw, preSharedKey: key); defer { tls.cancel() }
        try await tls.connect(timeout: 5)
        let negotiated = await tls.negotiatedCipher; XCTAssertEqual(negotiated, code)
        // Multiple TLS records, repeated writes, and reads smaller than records.
        let line = Data((0..<12000).map { UInt8(65 + $0 % 26) })
        let request = (0..<3).reduce(into: Data()) { data, _ in data.append(line); data.append(10) }
        let response = (0..<3).reduce(into: Data()) { data, _ in data.append(contentsOf: line.reversed()); data.append(10) }
        try await tls.send(request, timeout: 5)
        var actual = try await tls.readExactly(7, timeout: 5)
        actual.append(try await tls.readExactly(response.count - 7, timeout: 5))
        XCTAssertEqual(actual, response)
        try await tls.send(Data("again\n".utf8), timeout: 5)
        let again = try await tls.readExactly(6, timeout: 5); XCTAssertEqual(again, Data("niaga\n".utf8))
    }
    func testWrongPSKCannotCompleteHandshakeOrSendApplicationData() async throws {
        let server = try OpenSSLTestServer(); defer { server.stop() }
        let port = try await server.start()
        let tls = try PSKTLSTransport(upstream: TCPTransport(endpoint: ConnectionEndpoint(host: "127.0.0.1", port: String(port))), preSharedKey: Data(repeating: 0x42, count: 32))
        defer { tls.cancel() }
        do { try await tls.connect(timeout: 5); XCTFail("Wrong PSK must not authenticate") }
        catch { guard case .some(.network("OpenSSL", _)) = error as? TVPairError else { return XCTFail("Expected a TLS authentication error: \(error)") } }
        let cipher = await tls.negotiatedCipher; XCTAssertNil(cipher)
        do { try await tls.send(Data("forbidden".utf8), timeout: 1); XCTFail("Failed sessions must stay closed") }
        catch { XCTAssertEqual(error as? TVPairError, .closed) }
    }
    func testUnconfiguredCipherCannotFallBackToAnotherSuite() async throws {
        let server = try OpenSSLTestServer(cipher: "PSK-AES256-GCM-SHA384"); defer { server.stop() }
        let port = try await server.start()
        let tls = try PSKTLSTransport(upstream: TCPTransport(endpoint: ConnectionEndpoint(host: "127.0.0.1", port: String(port))), preSharedKey: key)
        defer { tls.cancel() }
        do { try await tls.connect(timeout: 5); XCTFail("Only the explicitly supported protocol suites may connect") }
        catch { guard case .some(.network("OpenSSL", _)) = error as? TVPairError else { return XCTFail("Expected cipher rejection: \(error)") } }
        let cipher = await tls.negotiatedCipher; XCTAssertNil(cipher)
    }
    func testTamperedRecordNeverReturnsPlaintext() async throws {
        let server = try OpenSSLTestServer(); defer { server.stop() }
        let port = try await server.start()
        let raw = TamperingTLSTransport(upstream: TCPTransport(endpoint: try ConnectionEndpoint(host: "127.0.0.1", port: String(port))))
        let tls = try PSKTLSTransport(upstream: raw, preSharedKey: key); defer { tls.cancel() }
        try await tls.connect(timeout: 5); raw.arm()
        try await tls.send(Data("authenticated\n".utf8), timeout: 5)
        do { _ = try await tls.readExactly(14, timeout: 5); XCTFail("Tampered ciphertext must not produce plaintext") }
        catch { guard case .some(.network("OpenSSL", _)) = error as? TVPairError else { return XCTFail("Expected record authentication failure: \(error)") } }
    }
    func testReadTimeoutClosesTheTLSStream() async throws {
        let server = try OpenSSLTestServer(); defer { server.stop() }
        let port = try await server.start()
        let tls = try PSKTLSTransport(upstream: TCPTransport(endpoint: ConnectionEndpoint(host: "127.0.0.1", port: String(port))), preSharedKey: key)
        defer { tls.cancel() }; try await tls.connect(timeout: 5)
        do { _ = try await tls.readExactly(1, timeout: 0.1); XCTFail("Silent peer must time out") }
        catch { XCTAssertEqual(error as? TVPairError, .timeout) }
    }
    func testCancellationUnblocksTLSRead() async throws {
        let server = try OpenSSLTestServer(); defer { server.stop() }
        let port = try await server.start()
        let tls = try PSKTLSTransport(upstream: TCPTransport(endpoint: ConnectionEndpoint(host: "127.0.0.1", port: String(port))), preSharedKey: key)
        defer { tls.cancel() }; try await tls.connect(timeout: 5)
        let read = Task { try await tls.readExactly(1, timeout: 10) }
        try await Task.sleep(for: .milliseconds(30)); read.cancel()
        do { _ = try await read.value; XCTFail("TLS read must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private final class OpenSSLTestServer: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    init(cipher: String = "PSK-AES256-CBC-SHA384") throws {
        let configured = ProcessInfo.processInfo.environment["TVPAIR_OPENSSL_CLI"]
        let candidates = [configured, "/opt/homebrew/opt/openssl@3/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            if configured != nil || ProcessInfo.processInfo.environment["CI"] != nil { throw TVPairError.unsupported("CI requires an OpenSSL 3 command-line peer for PSK integration tests") }
            throw XCTSkip("Install Homebrew OpenSSL 3 or set TVPAIR_OPENSSL_CLI to run the loopback PSK tests")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["s_server", "-accept", "127.0.0.1:0", "-nocert", "-tls1_2", "-cipher", cipher, "-psk", String(repeating: "41", count: 32), "-psk_identity", "", "-naccept", "1", "-rev", "-bufsize", "65536"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }
    func start() async throws -> UInt16 {
        let gate = OperationGate<UInt16>()
        try process.run()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            DispatchQueue.global().async { [self] in
                var line = Data(), total = 0
                do {
                    while total < 8192 {
                        guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { throw TVPairError.closed }
                        total += 1; line.append(byte)
                        if byte[0] == 10 {
                            let text = String(decoding: line, as: UTF8.self)
                            if text.hasPrefix("ACCEPT "), let suffix = text.split(separator: ":").last,
                               let port = UInt16(suffix.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 {
                                gate.finish(.success(port)); return
                            }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    throw TVPairError.malformed("OpenSSL test peer startup")
                } catch { gate.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
                if !gate.finished { gate.finish(.failure(TVPairError.timeout)); stop() }
            }
        }
    }
    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }
}

private final class TamperingTLSTransport: ByteTransport, @unchecked Sendable {
    let upstream: any ByteTransport
    private let lock = NSLock()
    private var armed = false
    init(upstream: any ByteTransport) { self.upstream = upstream }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    private func shouldTamper(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed && count > 5 else { return false }
        armed = false; return true
    }
    func connect(timeout: TimeInterval) async throws { try await upstream.connect(timeout: timeout) }
    func send(_ data: Data, timeout: TimeInterval) async throws { try await upstream.send(data, timeout: timeout) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        var data = try await upstream.readExactly(count, timeout: timeout).zeroBased
        if shouldTamper(count) { data[data.count - 1] ^= 1 }
        return data
    }
    func cancel() { upstream.cancel() }
}
