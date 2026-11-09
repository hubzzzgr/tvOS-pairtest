import Foundation

/// DNS-SD searches fail independently, particularly inside a guest host whose
/// Bonjour declarations may cover only some of the requested service types.
public struct DiscoveryHealth: Sendable {
    public private(set) var active: Set<ServiceKind> = []
    public private(set) var failures: [ServiceKind: Int32] = [:]
    public private(set) var observed: Set<ServiceKind> = []
    public init() {}
    public mutating func begin() {
        active = Set(ServiceKind.browsed); failures = [:]; observed = []
    }
    public mutating func stop() { active = [] }
    public mutating func found(_ kind: ServiceKind) { observed.insert(kind) }
    public mutating func failed(_ kind: ServiceKind, code: Int32) {
        failures[kind] = code; active.remove(kind)
    }
    public var isScanning: Bool { !active.isEmpty }
    public var message: String? {
        guard !failures.isEmpty else { return nil }
        let missing = failures.filter { $0.value == -72008 }.keys.sorted { $0.rawValue < $1.rawValue }
        if !missing.isEmpty {
            let types = missing.map(\.rawValue).joined(separator: ", ")
            return "Missing Bonjour configuration (-72008) for: \(types). This affects the system browser; other services can still appear. For Apple TV, try Enable developer access with its IP to perform a direct lookup. This error does not report the TV's developer state."
        }
        let details = failures.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.title) (DNS-SD \(failures[$0]!))" }.joined(separator: "; ")
        if active.isEmpty && observed.isEmpty {
            return "Bonjour searches stopped: \(details). Restart scanning. If the error persists, check Local Network settings and the host's Bonjour service declarations. These codes alone do not establish a permission denial."
        }
        return "Some Bonjour searches are unavailable: \(details). Other service types are still being searched."
    }
    public var offerSettings: Bool {
        observed.isEmpty && failures.values.contains { $0 == -65570 }
    }
}
