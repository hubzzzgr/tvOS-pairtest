import Foundation

public enum ProcessTestApp: String, CaseIterable, Identifiable, Sendable {
    case tikTok = "TikTok", instagram = "Instagram"
    public var id: String { rawValue }
    public var bundleIdentifier: String {
        switch self {
        case .tikTok: return "com.zhiliaoapp.musically"
        case .instagram: return "com.burbn.instagram"
        }
    }
}
public enum ProcessTestAction: String, Sendable {
    case pause = "Pause", resume = "Resume"
    var selector: String { self == .pause ? "suspendPid:" : "resumePid:" }
}
public enum ProcessTestOutcome: Equatable, Sendable {
    case notRunning, changed, acknowledged(pid: Int32)
    public func message(app: ProcessTestApp, action: ProcessTestAction) -> String {
        switch self {
        case .notRunning: return "\(app.rawValue) is not running. Open it on the paired device and try again."
        case .changed: return "\(app.rawValue)'s process changed before the request. No pause or resume was sent; try again."
        case .acknowledged: return "\(action.rawValue) request acknowledged for \(app.rawValue). Check the other device to confirm its behavior."
        }
    }
}
protocol ProcessControlRPC: Sendable {
    func invoke(_ selector: String, values: [DTXValue]) async throws -> DTXValue?
}
struct InstrumentsProcessRPC: ProcessControlRPC {
    let transport: InstrumentsTransport
    let channel: Int32
    func invoke(_ selector: String, values: [DTXValue]) async throws -> DTXValue? {
        try await transport.call(channel: channel, selector: selector, arguments: values.map { .object($0) })
    }
}
enum AppProcessTest {
    static func perform(app: ProcessTestApp, action: ProcessTestAction, rpc: any ProcessControlRPC) async throws -> ProcessTestOutcome {
        let arguments: [DTXValue] = [.string(app.bundleIdentifier)]
        let first = try await rpc.invoke("processIdentifierForBundleIdentifier:", values: arguments)
        if case let .some(.error(code)) = first { throw TVPairError.developer(code) }
        guard let pid = first?.integer, pid >= 0, pid <= Int32.max else { throw TVPairError.malformed("Instruments process identifier") }
        guard pid > 1 else { return .notRunning }
        // Resolve the exact bundle again immediately before acting; never use
        // substring matches, process names, or a cached PID from an earlier test.
        let current = try await rpc.invoke("processIdentifierForBundleIdentifier:", values: arguments)
        if case let .some(.error(code)) = current { throw TVPairError.developer(code) }
        guard let currentPID = current?.integer, currentPID >= 0, currentPID <= Int32.max else { throw TVPairError.malformed("Instruments current process identifier") }
        guard currentPID == pid else { return .changed }
        try Task.checkCancellation()
        let result = try await rpc.invoke(action.selector, values: [.integer(pid)])
        if case let .some(.error(code)) = result { throw TVPairError.developer(code) }
        guard result == nil || result == .null || result == .bool(true) else {
            throw result == .bool(false) ? TVPairError.developer(-1) : TVPairError.malformed("Instruments pause/resume acknowledgement")
        }
        return .acknowledged(pid: Int32(pid))
    }
}
