import Foundation
import Darwin

public enum TVPairError: Error, LocalizedError, Equatable {
    case invalidEndpoint, timeout, closed, cancelled
    case network(String, Int32)
    case malformed(String), unsupported(String), rejected(Int, Int?)
    case authentication, keychain(Int32), storage, invalidRecord(String)
    case advertisement(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Enter a valid IP address or hostname and a port from 1 to 65535. IPv6 link-local addresses need a scope, such as %en0."
        case .timeout: return "The operation timed out. Check Wi-Fi and the selected pairing flow, and keep TVPair and the other device's pairing screen open."
        case .closed: return "The peer closed the connection."
        case .cancelled: return "Cancelled."
        case let .network(domain, code): return "Network error (\(domain), \(code)). Check Local Network permission and Wi-Fi."
        case let .malformed(context): return "Unexpected protocol response: \(context)."
        case let .unsupported(context): return "Unsupported: \(context)."
        case let .rejected(code, retry): return "The device rejected pairing (code \(code))." + (retry.map { " Retry after \($0) seconds." } ?? "")
        case .authentication: return "Cryptographic authentication failed. No authenticated session was accepted."
        case let .advertisement(code): return "The pairable-host advertisement failed (DNS-SD code \(code)). Browsing other services may still work. In LiveContainer, the host must allow _remotepairing-pairable-host._tcp and Local Network access for incoming iPhone pairing."
        case let .keychain(code): return "Keychain access failed (OSStatus \(code)). LiveContainer may restrict guest Keychain access. Protected file storage is available only with your explicit consent."
        case .storage: return "Credential storage could not be read or written. Existing data was preserved."
        case let .invalidRecord(context): return "Invalid pairing record: \(context)."
        }
    }

    public static func safe(_ error: Error) -> TVPairError {
        if let error = error as? TVPairError { return error }
        if error is CancellationError { return .cancelled }
        // Never interpolate a peer response, file contents, PIN, or crypto error.
        return .malformed("operation failed; see the documented protocol stage")
    }
}

public struct ConnectionEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: String) throws {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        guard let number = UInt16(port), number > 0, !value.isEmpty, value.utf8.count <= 253,
              !value.contains(where: { $0.isWhitespace }), !value.contains("/"), !value.contains("@") else { throw TVPairError.invalidEndpoint }
        if value.contains(":") {
            let parts = value.split(separator: "%", omittingEmptySubsequences: false)
            var address = in6_addr()
            guard parts.count <= 2, inet_pton(AF_INET6, String(parts[0]), &address) == 1,
                  parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") })) else { throw TVPairError.invalidEndpoint }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 && parts.count != 2 { throw TVPairError.invalidEndpoint }
        } else {
            let name = value.hasSuffix(".") ? String(value.dropLast()) : value
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { throw TVPairError.invalidEndpoint }
            if name.allSatisfy({ $0.isNumber || $0 == "." }) {
                var address = in_addr()
                guard inet_pton(AF_INET, name, &address) == 1 else { throw TVPairError.invalidEndpoint }
            }
        }
        self.host = value
        self.port = number
    }
    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

public enum ServiceKind: String, Codable, CaseIterable, Sendable {
    case remotePairing = "_remotepairing._tcp."
    case manualPairing = "_remotepairing-manual-pairing._tcp."
    case lockdown = "_apple-mobdev2._tcp."
    case remoteDiscovery = "_remoted._tcp."
    case pairableHost = "_remotepairing-pairable-host._tcp."
    public static var browsed: [ServiceKind] { [.remotePairing, .manualPairing, .lockdown, .remoteDiscovery] }
    public init?(bonjourType: String) {
        let normalized = bonjourType.hasSuffix(".") ? bonjourType : bonjourType + "."
        self.init(rawValue: normalized)
    }
    public var supportsPairing: Bool { self == .manualPairing || self == .remotePairing }
    public var supportsNewPairing: Bool { self == .manualPairing }
    public var title: String {
        switch self {
        case .remotePairing: return "Remote Pairing"
        case .manualPairing: return "Manual Remote Pairing"
        case .lockdown: return "Lockdown advertisement"
        case .remoteDiscovery: return "Remote Service Discovery"
        case .pairableHost: return "Pairable host"
        }
    }
}

public struct AppleTVDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var service: ServiceKind
    public var hostname: String?
    public var addresses: [String]
    public var port: Int
    public var advertisedModel: String?
    public var resolutionError: Bool
    public var advertisedIdentifier: String?
    public var authenticationTag: String?
    public var endpoint: ConnectionEndpoint? {
        let candidates = [hostname].compactMap { $0 } + addresses
        return candidates.lazy.compactMap { try? ConnectionEndpoint(host: $0, port: String(port)) }.first
    }
    public var identityLabel: String {
        if let model = advertisedModel, model.hasPrefix("AppleTV") { return "Advertised Apple TV • identity unverified" }
        return "Device type unverified"
    }
    public init(id: String, name: String, service: ServiceKind, hostname: String? = nil, addresses: [String] = [], port: Int = 0, advertisedModel: String? = nil, resolutionError: Bool = false) {
        self.id = id; self.name = name; self.service = service; self.hostname = hostname
        self.addresses = addresses; self.port = port; self.advertisedModel = advertisedModel; self.resolutionError = resolutionError
    }
}

public struct DiscoveryState: Sendable {
    public private(set) var devices: [String: AppleTVDevice] = [:]
    public init() {}
    public mutating func update(_ device: AppleTVDevice) { devices[device.id] = device }
    public mutating func remove(id: String) { devices.removeValue(forKey: id) }
    public mutating func reset() { devices.removeAll() }
}

public enum PairingStage: String, Codable, Sendable, Hashable {
    case idle, advertising, awaitingPeer, connecting, negotiating, verifying, requestingConsent, awaitingPIN, displayingPIN, authenticating, persisting, openingTunnel, testingServices, finished, failed, cancelled
}

public struct PairingState: Sendable {
    public private(set) var stage: PairingStage = .idle
    public private(set) var authenticated = false
    public private(set) var trustedTunnel = false
    public var completeSuccess: Bool { authenticated && trustedTunnel && stage == .finished }
    public init() {}
    public mutating func move(to next: PairingStage) throws {
        let allowed: [PairingStage: Set<PairingStage>] = [
            .idle: [.connecting, .advertising], .advertising: [.awaitingPeer, .connecting], .awaitingPeer: [.connecting],
            .connecting: [.negotiating, .finished], .negotiating: [.verifying, .requestingConsent],
            .verifying: [.requestingConsent, .persisting, .openingTunnel],
            .requestingConsent: [.awaitingPIN, .displayingPIN, .authenticating], .awaitingPIN: [.authenticating], .displayingPIN: [.authenticating],
            .authenticating: [.persisting], .persisting: [.openingTunnel, .finished],
            .openingTunnel: [.testingServices, .finished], .testingServices: [.finished]
        ]
        guard next == .cancelled || next == .failed || allowed[stage, default: []].contains(next) else { throw TVPairError.malformed("invalid pairing state transition") }
        stage = next
    }
    public mutating func acceptAuthentication() throws {
        guard stage == .verifying || stage == .authenticating else { throw TVPairError.authentication }
        authenticated = true
    }
    public mutating func acceptTunnel() throws {
        guard authenticated && stage == .openingTunnel else { throw TVPairError.authentication }
        trustedTunnel = true
    }
}

public enum DiagnosticCheck: String, CaseIterable, Codable, Sendable {
    case discovery = "Bonjour discovery"
    case resolution = "Endpoint resolution"
    case tcp = "TCP connection"
    case initiation = "Pairing initiation"
    case authentication = "Pairing authentication"
    case persistence = "Pairing record persistence"
    case tunnel = "Trusted tunnel establishment"
    case services = "Developer-service availability"
    case information = "Device information retrieval"
}
public enum CheckResult: String, Codable, Sendable {
    case pending, running, passed, failed, blocked, cancelled
    case notAttempted = "not attempted"
}

public struct DiagnosticEvent: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let operation: DiagnosticCheck
    public let service: ServiceKind
    public let result: CheckResult
    public let message: String
    public let duration: TimeInterval
    public let errorDomain: String?
    public let errorCode: Int32?

    public init(operation: DiagnosticCheck, service: ServiceKind, result: CheckResult, message: String, duration: TimeInterval = 0, failure: TVPairError? = nil) {
        id = UUID(); timestamp = Date(); self.operation = operation; self.service = service
        self.result = result; self.message = LogSanitizer.sanitize(message); self.duration = duration
        switch failure {
        case let .some(.network(domain, code)) where ["POSIX", "DNS", "DNS-SD", "TLS", "Network.framework"].contains(domain): errorDomain = domain; errorCode = code
        case let .some(.keychain(code)): errorDomain = "OSStatus"; errorCode = code
        case let .some(.advertisement(code)): errorDomain = "DNS-SD"; errorCode = code
        case let .some(.rejected(code, _)): errorDomain = "Pairing"; errorCode = Int32(exactly: code)
        default: errorDomain = nil; errorCode = nil
        }
    }
}

public enum LogSanitizer {
    public static func sanitize(_ value: String) -> String {
        var output = value
        let patterns = [
            "(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
            "(?i)Bearer\\s+[^\\s]+",
            "(?i)(?:private[_ -]?key|public[_ -]?key|peer[_ -]?key|secret|password|pin|token|authorization|alt[_ -]?irk|hostKey|remote_unlock_host_key)\\s*[\"']?\\s*[:=]\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
            "(?<![A-Za-z0-9])[A-Za-z0-9+/]{40,}={0,2}(?![A-Za-z0-9])",
            "\\b[0-9]{4,8}\\b"
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return String(output.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.prefix(2000))
    }
    public static func export(_ events: [DiagnosticEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        return events.map { event in
            let code = event.errorCode.map { " | \(event.errorDomain ?? "Error") code \($0)" } ?? ""
            return "\(formatter.string(from: event.timestamp)) | \(event.operation.rawValue) | \(event.service.rawValue) | \(event.result.rawValue) | \(String(format: "%.3fs", event.duration))\(code) | \(sanitize(event.message))"
        }.joined(separator: "\n")
    }
}

public func displayText(_ value: String) -> String {
    String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160))
}
