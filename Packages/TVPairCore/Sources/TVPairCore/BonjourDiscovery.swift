import Foundation
import Network
import Combine
import Darwin

/// DNS-SD uses the system Bonjour implementation and needs no multicast entitlement.
@MainActor
public final class BonjourDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published public private(set) var devices: [AppleTVDevice] = []
    @Published public private(set) var scanning = false
    @Published public private(set) var networkStatus = "Checking network…"
    @Published public private(set) var discoveryMessage: String?
    @Published public private(set) var offerNetworkSettings = false
    public var onObservation: ((DiagnosticEvent) -> Void)?
    private var state = DiscoveryState()
    private var browsers: [NetServiceBrowser] = []
    private var browserKinds: [ObjectIdentifier: ServiceKind] = [:]
    private var health = DiscoveryHealth()
    private var services: [String: NetService] = [:]
    private let monitor = NWPathMonitor()
    private var refreshTimer: Timer?
    private var lastPath: NWPath.Status?

    public override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.networkStatus = path.status == .satisfied ? (path.usesInterfaceType(.wifi) ? "Wi-Fi available" : "Network available") : "Network unavailable"
                if self.lastPath != path.status, self.scanning { self.start() }
                self.lastPath = path.status
            }
        }
        monitor.start(queue: DispatchQueue(label: "TVPair.path"))
    }

    public func start() {
        stop(); state.reset(); publish(); health.begin(); publishHealth()
        for kind in ServiceKind.browsed {
            let browser = NetServiceBrowser()
            browser.delegate = self; browsers.append(browser)
            browserKinds[ObjectIdentifier(browser)] = kind
            browser.searchForServices(ofType: kind.rawValue, inDomain: "local.")
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshEndpoints() }
        }
    }

    public func stop() {
        refreshTimer?.invalidate(); refreshTimer = nil
        for browser in browsers { browser.delegate = nil; browser.stop() }
        for service in services.values { service.delegate = nil; service.stopMonitoring(); service.stop() }
        browsers.removeAll(); browserKinds.removeAll(); services.removeAll(); health.stop(); publishHealth()
    }

    private func key(_ service: NetService) -> String { "\(service.name)|\(service.type)|\(service.domain)" }
    private func publish() { devices = state.devices.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func publishHealth() {
        scanning = health.isScanning; discoveryMessage = health.message; offerNetworkSettings = health.offerSettings
        if !scanning { refreshTimer?.invalidate(); refreshTimer = nil }
    }
    private func refreshEndpoints() {
        // New resolvers avoid retaining old A/AAAA results across DHCP changes.
        for (id, old) in Array(services) {
            old.delegate = nil; old.stopMonitoring(); old.stop()
            let fresh = NetService(domain: old.domain, type: old.type, name: old.name)
            fresh.delegate = self; services[id] = fresh
            fresh.resolve(withTimeout: 5); fresh.startMonitoring()
        }
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard let kind = browserKinds[ObjectIdentifier(browser)], kind == ServiceKind(bonjourType: service.type) else { return }
        health.found(kind); publishHealth()
        let id = key(service)
        state.update(AppleTVDevice(id: id, name: displayText(service.name), service: kind))
        services[id]?.stop(); services[id] = service; service.delegate = self
        service.resolve(withTimeout: 5); service.startMonitoring(); publish()
        onObservation?(DiagnosticEvent(operation: .discovery, service: kind, result: .passed, message: "A service was observed. Its device identity has not been authenticated."))
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browserKinds[ObjectIdentifier(browser)] != nil else { return }
        let id = key(service)
        services[id]?.delegate = nil; services[id]?.stop(); services[id]?.stopMonitoring()
        services.removeValue(forKey: id); state.remove(id: id); publish()
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard let kind = browserKinds[ObjectIdentifier(browser)] else { return }
        let code = errorDict[NetService.errorCode]?.int32Value ?? 0
        health.failed(kind, code: code); publishHealth()
        onObservation?(DiagnosticEvent(operation: .discovery, service: kind, result: .failed, message: "The \(kind.title) Bonjour search stopped. Other service searches are independent.", failure: .network("DNS-SD", code)))
    }
    public func netServiceDidResolveAddress(_ sender: NetService) { update(sender) }
    public func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { update(sender, txtData: data) }
    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = key(sender)
        guard var device = state.devices[id], services[id] === sender else { return }
        device.hostname = nil; device.addresses = []; device.port = 0; device.resolutionError = true
        state.update(device); publish()
    }
    private func update(_ service: NetService, txtData: Data? = nil) {
        let id = key(service)
        guard var device = state.devices[id], services[id] === service else { return }
        device.hostname = service.hostName; device.port = service.port; device.resolutionError = false
        device.addresses = Array(Set((service.addresses ?? []).compactMap(Self.numericAddress))).sorted()
        if let txt = txtData ?? service.txtRecordData() {
            let values = NetService.dictionary(fromTXTRecord: txt)
            device.advertisedModel = ["model", "deviceModel", "modelName", "rpmd", "am"].compactMap { values[$0].flatMap { String(data: $0, encoding: .utf8) } }.first.map(displayText)
            device.advertisedIdentifier = values["identifier"].flatMap { String(data: $0, encoding: .utf8) }
            device.authenticationTag = values["authTag"].flatMap { String(data: $0, encoding: .utf8) }
        }
        state.update(device); publish()
    }
    public nonisolated static func numericAddress(_ data: Data) -> String? {
        data.withUnsafeBytes { raw in
            guard let address = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), raw.count >= 2 else { return nil }
            let family = Int32(address.pointee.sa_family)
            guard (family == AF_INET && raw.count >= MemoryLayout<sockaddr_in>.size) || (family == AF_INET6 && raw.count >= MemoryLayout<sockaddr_in6>.size) else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(raw.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: host)
        }
    }
    deinit { monitor.cancel() }
}
