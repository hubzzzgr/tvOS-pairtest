import Foundation
import Network

public protocol ByteTransport: Sendable {
    func connect(timeout: TimeInterval) async throws
    func send(_ data: Data, timeout: TimeInterval) async throws
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data
    func cancel()
}

/// Buffers a result if cancellation wins before continuation installation.
/// Every callback, timer and cancellation path completes the continuation at most once.
final class OperationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}

public final class TCPTransport: ByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "TVPair.tcp")
    public init(acceptedConnection: NWConnection) { connection = acceptedConnection }

    public init(endpoint: ConnectionEndpoint) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: parameters)
    }

    static func safeError(_ error: NWError) -> TVPairError {
        switch error {
        case let .posix(code): return .network("POSIX", code.rawValue)
        case let .dns(code): return .network("DNS", code)
        case let .tls(code): return .network("TLS", code)
        @unknown default: return .network("Network.framework", -1)
        }
    }
    private func execute<T>(timeout: TimeInterval, start: @escaping (OperationGate<T>) -> Void) async throws -> T {
        let gate = OperationGate<T>()
        let timer = DispatchWorkItem { [weak self] in
            gate.finish(.failure(TVPairError.timeout)); self?.cancel()
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                queue.async { if !gate.finished { start(gate) } }
                queue.asyncAfter(deadline: .now() + max(0.001, timeout), execute: timer)
            }
        } onCancel: { [weak self] in
            gate.finish(.failure(CancellationError())); self?.cancel()
        }
    }
    public func connect(timeout: TimeInterval = 10) async throws {
        try await execute(timeout: timeout) { [self] (gate: OperationGate<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case let .failed(error): gate.finish(.failure(Self.safeError(error)))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break // .waiting remains bounded by the timer, including denied permission.
                }
            }
            connection.start(queue: queue)
        }
    }
    public func send(_ data: Data, timeout: TimeInterval = 10) async throws {
        try await execute(timeout: timeout) { [self] (gate: OperationGate<Void>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { gate.finish(.failure(Self.safeError(error))) }
                else { gate.finish(.success(())) }
            })
        }
    }
    public func readExactly(_ count: Int, timeout: TimeInterval = 10) async throws -> Data {
        guard count >= 0 && count <= 1_048_576 else { throw TVPairError.malformed("read size limit") }
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while output.count < count {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { cancel(); throw TVPairError.timeout }
            let needed = count - output.count
            let chunk: Data = try await execute(timeout: remaining) { [self] gate in
                connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { data, _, complete, error in
                    if let data, !data.isEmpty { gate.finish(.success(data)) }
                    else if let error { gate.finish(.failure(Self.safeError(error))) }
                    else if complete { gate.finish(.failure(TVPairError.closed)) }
                    else { gate.finish(.failure(TVPairError.malformed("empty TCP receive"))) }
                }
            }
            output.append(chunk)
        }
        return output
    }
    public func cancel() { connection.cancel() }
    deinit { connection.cancel() }
}

public enum FramedJSON {
    public static func encode(_ value: [String: Any], magic: String = "RPPairing") throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard body.count <= 65535 else { throw TVPairError.malformed("frame length limit") }
        return Data(magic.utf8) + Data([UInt8(body.count >> 8), UInt8(body.count & 255)]) + body
    }
    public static func receive(from transport: any ByteTransport, magic: String = "RPPairing", timeout: TimeInterval = 10) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        let header = try await transport.readExactly(magic.utf8.count + 2, timeout: timeout).zeroBased
        guard header.prefix(magic.utf8.count) == Data(magic.utf8) else { throw TVPairError.malformed("invalid frame magic") }
        let length = Int(header[header.count - 2]) << 8 | Int(header[header.count - 1])
        guard length > 0, deadline.timeIntervalSinceNow > 0 else { throw TVPairError.malformed("empty frame or expired deadline") }
        let data = try await transport.readExactly(length, timeout: deadline.timeIntervalSinceNow)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TVPairError.malformed("JSON object required") }
        return object
    }
}

func nested(_ object: [String: Any], _ path: String...) -> Any? {
    path.reduce(object as Any?) { ($0 as? [String: Any])?[$1] }
}
