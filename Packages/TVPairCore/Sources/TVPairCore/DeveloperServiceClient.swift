import Foundation

public struct DeviceInformation: Sendable {
    public var name: String?
    public var identifier: String?
    public var productType: String?
    public var osVersion: String?
    public var developerServices: [String] = []
    public var deviceInfoServiceResponded = false
    public init() {}
}

public enum DeveloperServiceClient {
    public static func inspect(tunnel: TrustedTunnel, hostIdentifier: String, report: PairingReporter) async throws -> DeviceInformation {
        await report(.testingServices, .services, .running, "Opening RemoteXPC RSD through the authenticated tunnel using a userspace IPv6/TCP stream.")
        let xpc = RemoteXPCTransport(stream: try TunnelTCPTransport(tunnel: tunnel))
        try await xpc.open()
        guard let uuid = UUID(uuidString: hostIdentifier) else { throw TVPairError.invalidRecord("RemoteXPC requires a UUID host identifier") }
        try await xpc.send(.dictionary([
            "MessageType": .string("Handshake"), "MessagingProtocolVersion": .unsigned(7), "UUID": .uuid(uuid),
            "Properties": .dictionary(["RemoteXPCVersionFlags": .unsigned(0x0100000000000006), "SensitivePropertiesVisible": .bool(true)]),
            "Services": .dictionary([:])
        ]))
        guard let peer = try await xpc.receive().dictionary, let properties = peer["Properties"]?.dictionary,
              let services = peer["Services"]?.dictionary else { throw TVPairError.malformed("RSD peer properties and services") }
        var result = DeviceInformation()
        result.name = properties["DeviceName"]?.string.map(displayText)
        result.identifier = properties["UniqueDeviceID"]?.string.map(displayText)
        result.productType = properties["ProductType"]?.string.map(displayText)
        result.osVersion = properties["OSVersion"]?.string.map(displayText)
        result.developerServices = services.keys.filter { $0.hasPrefix("com.apple.coredevice.") || $0.hasPrefix("com.apple.instruments.") || $0.contains("debugserver") }.map(displayText).sorted()
        await report(.testingServices, .information, .passed, "Retrieved device-advertised RSD properties over the authenticated tunnel. Missing values remain unavailable.")
        guard let service = services["com.apple.coredevice.deviceinfo"]?.dictionary,
              let value = service["Port"]?.unsigned ?? service["Port"]?.string.flatMap(UInt64.init),
              let port = UInt16(exactly: value), port > 0 else {
            await report(.testingServices, .services, .blocked, "RSD responded but did not advertise com.apple.coredevice.deviceinfo. Developer Mode or a mounted developer image may be required.")
            return result
        }
        // Keep RSD alive. A second bounded stream opens the read-only device-info service.
        let developer = RemoteXPCTransport(stream: try TunnelTCPTransport(tunnel: tunnel, port: port))
        try await developer.open()
        let invocationID = UUID().uuidString
        try await developer.send(.dictionary([
            "CoreDevice.CoreDeviceDDIProtocolVersion": .signed(2),
            "CoreDevice.coreDeviceVersion": .dictionary(["components": .array([.unsigned(629), .unsigned(3)]), "originalComponentsCount": .signed(2), "stringValue": .string("629.3")]),
            "CoreDevice.deviceIdentifier": .string(hostIdentifier), "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.getdeviceinfo"),
            "CoreDevice.action": .dictionary([:]), "CoreDevice.input": .dictionary([:]),
            "CoreDevice.invocationIdentifier": .string(invocationID)
        ]), reply: true)
        guard let response = try await developer.receive().dictionary, response["CoreDevice.output"] != nil else { throw TVPairError.unsupported("the developer service did not return a successful getdeviceinfo output") }
        result.deviceInfoServiceResponded = true
        await report(.testingServices, .services, .passed, "The developer device-info service returned a getdeviceinfo output through the authenticated tunnel.")
        return result
    }
}
