import XCTest
import Network
@testable import TVPairCore

final class NetworkTests: XCTestCase {
    func testReadTimeoutClosesAnUnresponsiveConnection() async throws {
        let server = try LoopbackServer(); let port = try await server.start()
        let transport = TCPTransport(endpoint: try ConnectionEndpoint(host: "127.0.0.1", port: String(port)))
        defer { transport.cancel(); server.cancel() }
        try await transport.connect(timeout: 2)
        let start = Date()
        do { _ = try await transport.readExactly(1, timeout: 0.1); XCTFail("Unresponsive peer must time out") }
        catch { XCTAssertEqual(error as? TVPairError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testCancellationUnblocksReceivePromptly() async throws {
        let server = try LoopbackServer(); let port = try await server.start()
        let transport = TCPTransport(endpoint: try ConnectionEndpoint(host: "127.0.0.1", port: String(port)))
        defer { transport.cancel(); server.cancel() }
        try await transport.connect(timeout: 2)
        let task = Task { try await transport.readExactly(100, timeout: 10) }
        try await Task.sleep(for: .milliseconds(30)); let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Read must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testBadFrameMagicFailsWithoutPairing() async throws {
        let transport = ScriptedTransport(bytes: Data("NOTaPair!\0\0".utf8))
        let client = RemotePairingClient(transport: transport)
        do {
            _ = try await client.authenticate(endpoint: ConnectionEndpoint(host: "tv.local", port: "1234"), requestPIN: { XCTFail("No PIN for malformed handshake"); return "123456" }, report: { _,_,_,_ in })
            XCTFail("Malformed handshake cannot authenticate")
        } catch { XCTAssertEqual(error as? TVPairError, .malformed("invalid frame magic")) }
    }
    func testXPCFrameReassemblyAndSettingsAcknowledgement() async throws {
        let object = XPCValue.dictionary(["Properties": .dictionary(["OSVersion": .string("synthetic")])])
        let body = try XPCCodec.wrapper(object, flags: 0x101)
        let bytes = try RemoteXPCTransport.frame(type: 4) + RemoteXPCTransport.frame(type: 0, channel: 1, body: body.prefix(13)) + RemoteXPCTransport.frame(type: 0, channel: 1, body: body.dropFirst(13))
        let transport = ScriptedTransport(bytes: bytes), client = RemoteXPCTransport(stream: transport)
        let response = try await client.receive()
        XCTAssertEqual(response, object)
        XCTAssertFalse(transport.writes.isEmpty)
    }
}

private final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "TVPair.tests.loopback")
    var peers: [NWConnection] = []
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        let gate = OperationGate<UInt16>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state, let port = listener.port { gate.finish(.success(port.rawValue)) }
                if case .failed = state { gate.finish(.failure(TVPairError.closed)) }
            }
            listener.newConnectionHandler = { [self] connection in peers.append(connection); connection.start(queue: queue) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { gate.finish(.failure(TVPairError.timeout)) }
        }
    }
    func cancel() { queue.async { [self] in listener.cancel(); peers.forEach { $0.cancel() } } }
}

final class ScriptedTransport: ByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var sent: [Data] = []
    private var cancelled = false
    var writes: [Data] { lock.lock(); defer { lock.unlock() }; return sent }
    init(bytes: Data) { self.bytes = bytes }
    func connect(timeout: TimeInterval) async throws { try Task.checkCancellation() }
    private func write(_ data: Data) { lock.lock(); defer { lock.unlock() }; sent.append(data) }
    func send(_ data: Data, timeout: TimeInterval) async throws { try Task.checkCancellation(); write(data) }
    private func take(_ count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        guard bytes.count >= count else { throw TVPairError.closed }
        let output = Data(bytes.prefix(count)); bytes.removeFirst(count); return output
    }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try Task.checkCancellation(); return try take(count) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
