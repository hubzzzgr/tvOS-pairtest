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
        // A successful observation is direct evidence against a blanket denial.
        // Individual errors remain available in the service-specific diagnostics.
        guard observed.isEmpty, !failures.isEmpty else { return nil }
        let details = failures.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.title) (DNS-SD \(failures[$0]!))" }.joined(separator: "; ")
        if active.isEmpty {
            return "Bonjour searches stopped: \(details). Restart scanning. If the error persists, check Local Network settings and the host's Bonjour service declarations. These codes alone do not establish a permission denial."
        }
        return "Some Bonjour searches are unavailable: \(details). Other service types are still being searched."
    }
    public var offerSettings: Bool {
        observed.isEmpty && active.isEmpty && failures.values.contains { $0 == -72008 || $0 == -65570 }
    }
}
