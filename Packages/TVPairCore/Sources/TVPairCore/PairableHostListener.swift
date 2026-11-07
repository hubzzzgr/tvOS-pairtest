import Foundation
import Network

/// Publishes only while explicitly requested. Each listener accepts one peer;
/// additional connections are closed until the user starts another session.
@MainActor
public final class PairableHostListener: NSObject, @preconcurrency NetServiceDelegate {
    public let identity: PairableHostIdentity
    private var listener: NWListener?
    private var publisher: NetService?
    private var gate: OperationGate<TCPTransport>?
    private var accepted: TCPTransport?
    private var onPublished: (@Sendable () async -> Void)?
    private var timeoutTask: Task<Void, Never>?
    public init(identity: PairableHostIdentity) { self.identity = identity; super.init() }

    public func accept(onPublished: @escaping @Sendable () async -> Void) async throws -> TCPTransport {
        guard gate == nil else { throw TVPairError.malformed("listener already used") }
        let gate = OperationGate<TCPTransport>(); self.gate = gate; self.onPublished = onPublished
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            gate.finish(.failure(TVPairError.timeout)); self?.stop()
        }
        defer { timeoutTask?.cancel(); timeoutTask = nil }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                do {
                    let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
                    let listener = try NWListener(using: parameters, on: .any)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self, !gate.finished else { connection.cancel(); return }
                            let transport = TCPTransport(acceptedConnection: connection)
                            self.accepted = transport; gate.finish(.success(transport))
                        }
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in
                            guard let self, !gate.finished else { return }
                            switch state {
                            case .ready:
                                guard let port = self.listener?.port else { gate.finish(.failure(TVPairError.invalidEndpoint)); return }
                                self.publish(port: port.rawValue)
                            case let .failed(error): gate.finish(.failure(TCPTransport.safeError(error)))
                            case .cancelled: gate.finish(.failure(CancellationError()))
                            default: break
                            }
                        }
                    }
                    listener.start(queue: DispatchQueue(label: "TVPair.pairable-host"))
                } catch { gate.finish(.failure(TVPairError.safe(error))) }
            }
        } onCancel: { [weak self] in
            gate.finish(.failure(CancellationError()))
            Task { @MainActor in self?.stop() }
        }
    }
    private func publish(port: UInt16) {
        guard publisher == nil else { return }
        let service = NetService(domain: "local.", type: ServiceKind.pairableHost.rawValue, name: identity.identifier, port: Int32(port))
        publisher = service; service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: identity.txtRecords))
        service.publish()
    }
    public func netServiceDidPublish(_ sender: NetService) {
        guard sender === publisher, let callback = onPublished else { return }
        onPublished = nil
        Task { await callback() }
    }
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === publisher else { return }
        gate?.finish(.failure(TVPairError.advertisement(errorDict[NetService.errorCode]?.int32Value ?? 0)))
    }
    public func stop() {
        gate?.finish(.failure(CancellationError())); timeoutTask?.cancel(); timeoutTask = nil
        publisher?.delegate = nil; publisher?.stop(); publisher = nil
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        accepted?.cancel(); accepted = nil; onPublished = nil
    }
}
