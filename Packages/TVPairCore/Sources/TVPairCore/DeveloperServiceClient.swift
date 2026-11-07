import Foundation

public enum BackboardTerminationOutcome: Sendable {
    case notRunning, changed, acknowledged
    public var message: String {
        switch self {
        case .notRunning: return "backboardd was not present in the paired device's process list. No termination request was sent."
        case .changed: return "BackBoard's process changed. No termination request was sent; try again."
        case .acknowledged: return "BackBoard termination request acknowledged. The paired device may restart its graphical session and disconnect. Acknowledgement does not verify termination."
        }
    }
}

public struct DeviceInformation: Sendable {
    public var name: String?
    public var nameSource: String?
    public var identifier: String?
    public var productType: String?
    public var osVersion: String?
    public var developerServices: [String] = []
    public var developerServiceDetail = "Developer services have not been tested."
    public var deviceInfoServiceResponded = false
    public var instrumentsServiceResponded = false
    public init() {}

    static func fromRSD(properties: [String: XPCValue], services: [String: XPCValue], savedName: String?) -> Self {
        var result = Self()
        if let name = usableName(properties["DeviceName"]?.string) { result.name = name; result.nameSource = "RSD properties" }
        else if let name = usableName(savedName) { result.name = name; result.nameSource = "Saved pairing record" }
        result.identifier = properties["UniqueDeviceID"]?.string.map(displayText)
        result.productType = properties["ProductType"]?.string.map(displayText)
        result.osVersion = properties["OSVersion"]?.string.map(displayText)
        result.developerServices = services.keys.filter { $0.hasPrefix("com.apple.coredevice.") || $0.hasPrefix("com.apple.instruments.") || $0.contains("debugserver") }.map(displayText).sorted()
        return result
    }
    private static func usableName(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = displayText(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !["unavailable", "imported device"].contains(clean.lowercased()) else { return nil }
        return clean
    }
}

/// Retained while the result is displayed. One user operation runs at a time;
/// no background reader consumes another stream's tunnel packets.
public actor DeveloperConnection {
    private nonisolated let tunnel: TrustedTunnel
    private let hostIdentifier: String
    private let savedName: String?
    private var rsd: RemoteXPCTransport?
    private var instruments: InstrumentsTransport?
    private var deviceInfoChannel: Int32?
    private var processRPC: InstrumentsProcessRPC?
    private var operating = false
    public init(tunnel: TrustedTunnel, hostIdentifier: String, savedName: String?) {
        self.tunnel = tunnel; self.hostIdentifier = hostIdentifier; self.savedName = savedName
    }
    public nonisolated func cancel() { tunnel.transport.cancel() }
    public func inspect(report: PairingReporter, updateInformation: @Sendable (DeviceInformation) async -> Void = { _ in }) async throws -> DeviceInformation {
        guard !operating else { throw TVPairError.malformed("concurrent developer operation") }
        operating = true; defer { operating = false }
        await report(.testingServices, .services, .running, "Opening RemoteXPC RSD through the authenticated tunnel.")
        let xpc = RemoteXPCTransport(stream: try TunnelTCPTransport(tunnel: tunnel)); rsd = xpc
        try await xpc.open()
        guard let uuid = UUID(uuidString: hostIdentifier) else { throw TVPairError.invalidRecord("RemoteXPC requires a UUID host identifier") }
        try await xpc.send(.dictionary([
            "MessageType": .string("Handshake"), "MessagingProtocolVersion": .unsigned(7), "UUID": .uuid(uuid),
            "Properties": .dictionary(["RemoteXPCVersionFlags": .unsigned(0x0100000000000006), "SensitivePropertiesVisible": .bool(true)]), "Services": .dictionary([:])
        ]))
        guard let peer = try await xpc.receive().dictionary, let properties = peer["Properties"]?.dictionary,
              let services = peer["Services"]?.dictionary else { throw TVPairError.malformed("RSD peer properties and services") }
        var result = DeviceInformation.fromRSD(properties: properties, services: services, savedName: savedName)
        await updateInformation(result)
        await report(.testingServices, .information, .passed, "Retrieved RSD properties over the authenticated tunnel. A missing RSD name may use the labelled saved-record name.")
        var failure: TVPairError?
        if let port = Self.port(services["com.apple.instruments.dtservicehub"]) {
            await report(.testingServices, .services, .running, "Probing the advertised Instruments hub with its DTX handshake and a read-only runningProcesses request.")
            do {
                // Native dtservicehub carries raw DTX, without lockdown RSDCheckin.
                let client = InstrumentsTransport(stream: try TunnelTCPTransport(tunnel: tunnel, port: port))
                try await client.open()
                let channel = try await client.channel("com.apple.instruments.server.services.deviceinfo")
                guard case .some(.array(_)) = try await client.call(channel: channel, selector: "runningProcesses") else { throw TVPairError.malformed("Instruments running-process list") }
                instruments = client; deviceInfoChannel = channel; result.instrumentsServiceResponded = true
                result.developerServiceDetail = "Instruments deviceinfo responded to a read-only request. App process control is a separate permission test."
                await report(.testingServices, .services, .passed, result.developerServiceDetail)
                await updateInformation(result); return result
            } catch {
                try Task.checkCancellation()
                failure = TVPairError.safe(error)
            }
        }
        if let port = Self.port(services["com.apple.coredevice.deviceinfo"]) {
            await report(.testingServices, .services, .running, "Probing the advertised CoreDevice device-info service.")
            do {
                let developer = RemoteXPCTransport(stream: try TunnelTCPTransport(tunnel: tunnel, port: port))
                try await developer.open()
                try await developer.send(.dictionary([
                    "CoreDevice.CoreDeviceDDIProtocolVersion": .signed(2),
                    "CoreDevice.coreDeviceVersion": .dictionary(["components": .array([.unsigned(629), .unsigned(3)]), "originalComponentsCount": .signed(2), "stringValue": .string("629.3")]),
                    "CoreDevice.deviceIdentifier": .string(hostIdentifier), "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.getdeviceinfo"),
                    "CoreDevice.action": .dictionary([:]), "CoreDevice.input": .dictionary([:]), "CoreDevice.invocationIdentifier": .string(UUID().uuidString)
                ]), reply: true)
                guard let response = try await developer.receive().dictionary, response["CoreDevice.output"]?.dictionary != nil else { throw TVPairError.unsupported("the developer service did not return a getdeviceinfo output dictionary") }
                result.deviceInfoServiceResponded = true
                result.developerServiceDetail = "CoreDevice deviceinfo returned a getdeviceinfo output. Instruments process control was not verified."
                await report(.testingServices, .services, .passed, result.developerServiceDetail)
                await updateInformation(result); return result
            } catch {
                try Task.checkCancellation()
                failure = TVPairError.safe(error)
            }
        }
        if let failure {
            result.developerServiceDetail = "An advertised developer service was probed but did not complete: " + failure.localizedDescription
            await report(.testingServices, .services, .failed, result.developerServiceDetail)
        } else {
            result.developerServiceDetail = "RSD responded, but neither the supported Instruments hub nor CoreDevice deviceinfo advertised a usable port. No developer request was sent."
            await report(.testingServices, .services, .blocked, result.developerServiceDetail)
        }
        await updateInformation(result); return result
    }
    static func port(_ service: XPCValue?) -> UInt16? {
        guard let dict = service?.dictionary, let number = dict["Port"]?.unsigned ?? dict["Port"]?.string.flatMap(UInt64.init),
              let port = UInt16(exactly: number), port > 0 else { return nil }
        return port
    }
    public func perform(app: ProcessTestApp, action: ProcessTestAction) async throws -> ProcessTestOutcome {
        guard !operating else { throw TVPairError.malformed("concurrent developer operation") }
        operating = true; defer { operating = false }
        guard let instruments else { throw TVPairError.unsupported("the Instruments service has not passed its read-only probe; reconnect and check developer-service details") }
        if processRPC == nil {
            let channel = try await instruments.channel("com.apple.instruments.server.services.processcontrol")
            processRPC = InstrumentsProcessRPC(transport: instruments, channel: channel)
        }
        guard let rpc = processRPC else { throw TVPairError.malformed("Instruments process channel") }
        return try await AppProcessTest.perform(app: app, action: action, rpc: rpc)
    }
    /// Explicit manual action scoped to the paired device's exact backboardd
    /// process. No caller-provided PID, name or signal is accepted.
    public func terminateBackboard() async throws -> BackboardTerminationOutcome {
        guard !operating else { throw TVPairError.malformed("concurrent developer operation") }
        operating = true; defer { operating = false }
        guard let instruments, let deviceInfoChannel else {
            throw TVPairError.unsupported("the Instruments service has not passed its read-only probe")
        }
        // Open the control channel before resolving the target, to minimize the
        // interval between fresh process identification and the signal request.
        if processRPC == nil {
            let channel = try await instruments.channel("com.apple.instruments.server.services.processcontrol")
            processRPC = InstrumentsProcessRPC(transport: instruments, channel: channel)
        }
        guard let rpc = processRPC else { throw TVPairError.malformed("Instruments process channel") }
        guard let pid = try await backboardPID(instruments, channel: deviceInfoChannel) else {
            return .notRunning
        }
        guard try await backboardPID(instruments, channel: deviceInfoChannel) == pid else {
            return .changed
        }
        let executable = try await instruments.call(channel: deviceInfoChannel, selector: "execnameForPid:", arguments: [.object(.integer(pid))])
        guard let path = executable?.string, path.split(separator: "/").last == "backboardd" else {
            throw TVPairError.unsupported("the device did not confirm the backboardd executable; no termination request was sent")
        }
        try Task.checkCancellation()
        // The reply-bearing signal selector avoids treating a fire-and-forget
        // killPid: write as device acknowledgement.
        let result = try await rpc.invoke("sendSignal:toPid:", values: [.integer(9), .integer(pid)])
        if case let .some(.error(code)) = result { throw TVPairError.developer(code) }
        guard result == nil || result == .null || result == .bool(true) else {
            throw result == .bool(false) ? TVPairError.developer(-1) : TVPairError.malformed("Instruments BackBoard termination acknowledgement")
        }
        return .acknowledged
    }
    private func backboardPID(_ client: InstrumentsTransport, channel: Int32) async throws -> Int64? {
        guard case let .some(.array(processes)) = try await client.call(channel: channel, selector: "runningProcesses") else {
            throw TVPairError.malformed("Instruments running-process list")
        }
        let matches = processes.compactMap(\.dictionary).filter { $0["name"]?.string == "backboardd" }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let pid = matches[0]["pid"]?.integer, pid > 1, pid <= Int32.max else {
            throw TVPairError.malformed("Instruments ambiguous or invalid BackBoard process identifier")
        }
        return pid
    }
}
