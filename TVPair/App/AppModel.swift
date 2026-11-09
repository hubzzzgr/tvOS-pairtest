import SwiftUI
import TVPairCore

struct ServiceTestSnapshot {
    let endpoint: ConnectionEndpoint
    let service: ServiceKind
    let checks: [DiagnosticCheck: CheckResult]
    let message: String
    let finishedAt: Date
}

@MainActor
final class AppModel: ObservableObject {
    let discovery = BonjourDiscovery()
    private let vault = CredentialVault()
    @Published var saved: [SavedDevice] = []
    @Published var events: [DiagnosticEvent] = []
    @Published var checks: [DiagnosticCheck: CheckResult] = [:]
    @Published private(set) var serviceTests: [String: ServiceTestSnapshot] = [:]
    @Published var state = PairingState()
    @Published var busy = false
    @Published var presentPairing = false
    @Published var message = "Select an advertised service or enter an endpoint."
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published var fileStorage = UserDefaults.standard.bool(forKey: "TVPair.protectedFileStorage")
    @Published var pin = ""
    @Published var information = DeviceInformation()
    @Published private(set) var processBusy = false
    @Published private(set) var processResults: [ProcessTestApp: String] = [:]
    @Published private(set) var backboardResult: String?
    @Published private(set) var activationBusy = false
    @Published private(set) var activationMessage: String?
    private var activationTask: Task<Void, Never>?
    private var activationToken: UUID?
    private var directProbe: DirectPairingProbe?
    private var developerConnection: DeveloperConnection?
    private var processOperation: Task<Void, Never>?
    var canTestProcesses: Bool { !busy && !processBusy && information.instrumentsServiceResponded && developerConnection != nil }
    @Published private(set) var hostPIN: String?
    @Published private(set) var hosting = false
    @Published private(set) var tcpOnly = false
    private var hostListener: PairableHostListener?
    private var hostRecordID: UUID?
    private var hostEndpoint: ConnectionEndpoint?
    var canRetryHostedConnection: Bool {
        !busy && !processBusy && hosting && hostEndpoint != nil && saved.contains { $0.id == hostRecordID }
    }
    @Published var lastSavedID: UUID?
    private var operation: Task<Void, Never>?
    private var activeTransport: (any ByteTransport)?
    private var pinContinuation: CheckedContinuation<String, Error>?
    private var pinRequestID: UUID?
    private var pendingRecord: PairingRecord?
    private var service: ServiceKind = .remotePairing
    private var started = Date()
    private var stageStart: [DiagnosticCheck: Date] = [:]
    private var activeCheck: DiagnosticCheck?
    var stage: PairingStage { state.stage }
    private var selectedDeviceSymbol = "network"
    var connectionSystemImage: String {
        let family = DeviceFamily.model(information.productType)
        return family == .unknown ? selectedDeviceSymbol : family.systemImage
    }
    var fullSuccess: Bool { state.completeSuccess && checks[.services] == .passed && checks[.information] == .passed }
    var summary: String {
        if busy {
            if tcpOnly { return "Testing TCP connection" }
            if stage == .awaitingPIN { return "Enter the Apple TV code" }
            if stage == .displayingPIN { return "Enter this code on the other device" }
            if stage == .advertising || stage == .awaitingPeer { return "Waiting for the other iPhone" }
            return "Testing the connection"
        }
        if fullSuccess { return "Developer connection verified" }
        if state.authenticated { return state.trustedTunnel ? "Authenticated tunnel verified" : "Pairing authenticated • tunnel unverified" }
        if stage == .cancelled { return "Connection cancelled" }
        if tcpOnly { return stage == .finished && checks[.tcp] == .passed ? "TCP connection succeeded" : "TCP connection failed" }
        return "Connection not authenticated"
    }
    init() {
        ShareItem.cleanup()
        discovery.onObservation = { [weak self] event in self?.append(event) }
    }
    private var protectedDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVPair", isDirectory: true) }
    func loadRecords() async {
        do {
            if fileStorage { saved = try await vault.selectProtectedFile(directory: protectedDirectory, explicitConsent: true) }
            else { saved = try await vault.load() }
            storageError = nil
        } catch { storageError = TVPairError.safe(error).localizedDescription }
    }
    func enableProtectedStorage() async {
        do {
            saved = try await vault.selectProtectedFile(directory: protectedDirectory, explicitConsent: true)
            fileStorage = true; UserDefaults.standard.set(true, forKey: "TVPair.protectedFileStorage"); storageError = nil
            if let pendingRecord { saved = try await vault.save(pendingRecord); lastSavedID = pendingRecord.id; self.pendingRecord = nil
                log(.persistence, .passed, "Saved the pending record after explicit selection of protected app-container storage.")
            }
        } catch { storageError = TVPairError.safe(error).localizedDescription }
    }
    func retryStorage() async {
        do {
            if let pendingRecord { saved = try await vault.save(pendingRecord); lastSavedID = pendingRecord.id; self.pendingRecord = nil; log(.persistence, .passed, "Saved the pending credentials. An imported record does not authenticate a session.") }
            else { saved = try await vault.load() }
            storageError = nil
        } catch { storageError = TVPairError.safe(error).localizedDescription }
    }
    func append(_ event: DiagnosticEvent) { events.append(event); if events.count > 1000 { events.removeFirst(events.count - 1000) } }
    private func log(_ check: DiagnosticCheck, _ result: CheckResult, _ text: String, failure: TVPairError? = nil) {
        checks[check] = result
        if result == .running { stageStart[check] = Date(); activeCheck = check }
        else if activeCheck == check { activeCheck = nil }
        append(DiagnosticEvent(operation: check, service: service, result: result, message: text, duration: stageStart[check].map { Date().timeIntervalSince($0) } ?? 0, failure: failure))
    }
    private func report(_ stage: PairingStage, _ check: DiagnosticCheck, _ result: CheckResult, _ text: String) {
        do { if stage != state.stage { try state.move(to: stage) } }
        catch { errorMessage = TVPairError.safe(error).localizedDescription }
        message = text; log(check, result, text)
    }
    func validatePairingEndpoint(_ endpoint: ConnectionEndpoint, service: ServiceKind) throws {
        guard service.supportsPairing else { return }
        let matches = discovery.devices.filter { $0.matchesNetworkEndpoint(endpoint) }
        // A positive pairing advertisement on this exact location takes
        // precedence; other advertisements do not prove pairing is impossible.
        guard !matches.contains(where: { $0.service.supportsPairing }) else { return }
        if let other = matches.first(where: { !$0.service.supportsPairing }) {
            throw TVPairError.unsupported("this host and port are currently advertised as \(other.service.title), not Remote Pairing. Use Test TCP connection on that service's details page. For Apple TV developer pairing, select its separate Manual Remote Pairing advertisement and port")
        }
    }
    func enableAppleTVDeveloperAccess(host: String) {
        guard !busy && !processBusy else { return }
        finishPresentation()
        let probe: DirectPairingProbe
        do { probe = try DirectPairingProbe(host: host) }
        catch { activationMessage = TVPairError.safe(error).localizedDescription; return }
        let token = UUID(); activationToken = token; directProbe = probe
        busy = true; activationBusy = true
        activationMessage = "Asking the selected TV directly for its developer pairing endpoint…"
        activationTask = Task { [weak self] in
            guard let self else { return }
            let began = Date()
            defer {
                if self.activationToken == token {
                    self.busy = false; self.activationBusy = false; self.activationToken = nil
                    self.activationTask = nil; self.directProbe = nil
                }
            }
            do {
                let endpoint = try await probe.resolve(.manualPairing)
                try Task.checkCancellation()
                self.append(DiagnosticEvent(operation: .discovery, service: .manualPairing, result: .passed, message: "Direct DNS-SD returned a developer pairing endpoint from the selected IP. Device identity is not authenticated.", duration: Date().timeIntervalSince(began)))
                self.activationMessage = "Pairing endpoint found. Waiting for the Apple TV code exchange; developer access is not yet verified."
                self.activationToken = nil; self.activationTask = nil; self.directProbe = nil
                self.busy = false; self.activationBusy = false
                self.start(endpoint: endpoint, service: .manualPairing, discovered: false, activationHost: endpoint.host)
            } catch {
                let safe = TVPairError.safe(error)
                self.activationMessage = safe == .timeout
                    ? "The selected TV did not answer the direct DNS query. Keep Remote App and Devices open on it, check the IP, and retry. No developer activation or pairing request was sent."
                    : safe == .cancelled || Task.isCancelled ? "Developer setup cancelled." : safe.localizedDescription
                self.append(DiagnosticEvent(operation: .discovery, service: .manualPairing, result: Task.isCancelled ? .cancelled : .failed, message: self.activationMessage ?? "Direct developer lookup failed.", duration: Date().timeIntervalSince(began), failure: safe))
            }
        }
    }
    private func regularEndpointFromScan(host: String, record: PairingRecord) -> ConnectionEndpoint? {
        let candidates = discovery.devices.filter { device in
            guard device.service == .remotePairing, let candidate = try? ConnectionEndpoint(host: host, port: String(device.port)) else { return false }
            return device.matchesNetworkEndpoint(candidate)
        }
        let tagged = candidates.filter { AdvertisementIdentity.matches(record: record, identifier: $0.advertisedIdentifier, authTag: $0.authenticationTag) }
        let ports = Set((tagged.isEmpty ? candidates : tagged).map(\.port))
        guard ports.count == 1, let port = ports.first else { return nil }
        // This is an endpoint hint on the original chosen IP. The next step
        // still requires the saved record's pinned peer signature.
        return try? ConnectionEndpoint(host: host, port: String(port))
    }
    private func waitForAppleTVRegularEndpoint(host: String, record: PairingRecord) async throws -> ConnectionEndpoint {
        if let endpoint = regularEndpointFromScan(host: host, record: record) { return endpoint }
        if !discovery.scanning { discovery.start() }
        let deadline = Date().addingTimeInterval(20)
        var attempt = 0
        while deadline.timeIntervalSinceNow > 0 {
            try Task.checkCancellation()
            if let endpoint = regularEndpointFromScan(host: host, record: record) {
                log(.tunnel, .running, "The TV's regular endpoint appeared in discovery. Verifying the saved peer identity next.")
                return endpoint
            }
            attempt += 1
            log(.tunnel, .running, "Pairing and record saving succeeded. Waiting for the TV's regular endpoint to become available (lookup \(attempt)); TLS has not started.")
            let probe = try DirectPairingProbe(host: host); directProbe = probe
            do {
                let endpoint = try await probe.resolve(.remotePairing, timeout: min(5, deadline.timeIntervalSinceNow))
                directProbe = nil
                log(.tunnel, .running, "The TV's regular endpoint answered a direct lookup. Verifying the saved peer identity next.")
                return endpoint
            } catch {
                probe.cancel(); directProbe = nil
                try Task.checkCancellation()
                // A fresh advertisement can arrive while a direct query waits.
                if let endpoint = regularEndpointFromScan(host: host, record: record) {
                    log(.tunnel, .running, "The TV's regular endpoint appeared during the lookup. Verifying the saved peer identity next.")
                    return endpoint
                }
                let safe = TVPairError.safe(error)
                append(DiagnosticEvent(operation: .tunnel, service: .remotePairing, result: .running, message: "Regular-endpoint lookup did not complete; waiting within the post-pairing handoff deadline. " + safe.localizedDescription, failure: safe))
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 { try await Task.sleep(for: .seconds(min(1, remaining))) }
        }
        throw TVPairError.unsupported("pairing and record saving succeeded, but the TV's regular endpoint was not available within 20 seconds. No TLS handshake was attempted. Rescan and reconnect using the saved record; there is no need to pair again")
    }
    func start(endpoint: ConnectionEndpoint, service: ServiceKind, discovered: Bool, recordID: UUID? = nil, deviceID: String? = nil, activationHost: String? = nil) {
        guard !busy && !processBusy else { return }
        do { if activationHost == nil { try validatePairingEndpoint(endpoint, service: service) } }
        catch { errorMessage = TVPairError.safe(error).localizedDescription; return }
        let selected = discovery.devices.first { device in
            device.service == service && (deviceID.map { device.id == $0 } ?? (discovered && device.endpoint == endpoint))
        }
        let testedServiceID = selected?.id
        developerConnection?.cancel(); developerConnection = nil; processResults = [:]; backboardResult = nil
        selectedDeviceSymbol = selected?.systemImage ?? "network"
        // A retry for this onboarding record must not tear down the channel
        // that may be keeping the other iPhone's session-limited trust alive.
        if !(hosting && recordID != nil && recordID == hostRecordID) { finishPresentation() }
        busy = true; presentPairing = true; self.service = service; checks = [:]; state = PairingState()
        tcpOnly = !service.supportsPairing || (recordID == nil && !service.supportsNewPairing)
        information = DeviceInformation(); errorMessage = nil; lastSavedID = nil; pin = ""; started = Date(); stageStart = [:]; activeCheck = nil
        log(.discovery, discovered || activationHost != nil ? .passed : .blocked, activationHost != nil ? "Selected a fresh direct DNS-SD pairing answer from the chosen TV. It remains unauthenticated until the code exchange completes." : discovered ? "Selected a currently discovered service." : "Manual endpoint; Bonjour discovery was bypassed.")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.directProbe?.cancel(); self.directProbe = nil
                if self.developerConnection == nil { self.activeTransport?.cancel() }
                self.activeTransport = nil; self.busy = false
                self.pinContinuation?.resume(throwing: CancellationError()); self.pinContinuation = nil; self.pin = ""
                for check in DiagnosticCheck.allCases where self.checks[check] == nil || self.checks[check] == .running {
                    let skipped = self.tcpOnly && ![DiagnosticCheck.discovery, .resolution, .tcp].contains(check)
                    self.log(check, skipped ? .notAttempted : self.stage == .cancelled ? .cancelled : .blocked, skipped ? "This check is outside the selected TCP-only test." : "This check did not complete in this attempt.")
                }
                if let testedServiceID {
                    self.serviceTests[testedServiceID] = ServiceTestSnapshot(endpoint: endpoint, service: service, checks: self.checks, message: self.message, finishedAt: Date())
                }
                self.operation = nil
            }
            do {
                let transport = TCPTransport(endpoint: endpoint); self.activeTransport = transport
                if self.tcpOnly {
                    self.report(.connecting, .tcp, .running, "Testing TCP only for this service type.")
                    try await transport.connect(timeout: 10)
                    self.log(.resolution, .passed, "Endpoint resolved as part of the TCP connection.")
                    self.log(.tcp, .passed, "TCP connected. No pairing protocol was sent to this service.")
                    self.log(.initiation, .notAttempted, service == .remotePairing ? "This regular Remote Pairing endpoint requires a saved record. For an iPhone or iPad, use Pair with iPhone / iPad on Devices and start pairing from the other device's Paired Macs screen (iOS 27+). Apple TV uses its separate Manual Remote Pairing service." : service.discoveryOnly ? "This AirPlay/Companion endpoint provides discovery and a TCP test only. Use Apple's Manual Remote Pairing service to begin developer pairing; its port is separate." : "Lockdown and RSD advertisements are not interchangeable with RPPairing endpoints.")
                    try self.state.move(to: .finished); self.message = "TCP test completed. Authentication was not attempted."; return
                }
                let record = try await recordID.mapAsync { try await self.vault.record(id: $0) }
                let client = RemotePairingClient(transport: transport)
                let reporter: PairingReporter = { [weak self] stage, check, result, message in
                    await self?.report(stage, check, result, message)
                }
                let authenticated = try await client.authenticate(endpoint: endpoint, service: service, existingRecord: record, requestPIN: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.waitForPIN()
                }, report: reporter)
                try Task.checkCancellation(); try self.state.acceptAuthentication()
                self.report(.persisting, .persistence, .running, "Saving authenticated credentials in the selected secure storage.")
                do {
                    self.saved = try await self.vault.save(authenticated); self.lastSavedID = authenticated.id
                    self.log(.persistence, .passed, "Credentials persisted successfully.")
                } catch {
                    self.pendingRecord = authenticated; self.storageError = TVPairError.safe(error).localizedDescription
                    self.log(.persistence, .failed, "Credential persistence failed. The record remains in memory for an explicit retry during this app session.", failure: TVPairError.safe(error))
                }
                try Task.checkCancellation()
                self.report(.openingTunnel, .tunnel, .running, "Requesting an authenticated TCP listener, then testing TLS-PSK and CDTunnel.")
                var trustedClient = client, trustedEndpoint = endpoint
                if record == nil {
                    // Pair-Setup endpoints may close after M6. Prove saved-record reuse
                    // on a fresh connection before attempting any tunnel operation.
                    transport.cancel()
                    if let activationHost {
                        trustedEndpoint = try await self.waitForAppleTVRegularEndpoint(host: activationHost, record: authenticated)
                        self.service = .remotePairing
                    } else if service == .manualPairing, let regular = self.discovery.devices.first(where: {
                        $0.service == .remotePairing && $0.endpoint != nil && AdvertisementIdentity.matches(record: authenticated, identifier: $0.advertisedIdentifier, authTag: $0.authenticationTag)
                    }), let resolved = regular.endpoint {
                        trustedEndpoint = resolved; self.service = .remotePairing
                        self.log(.tunnel, .running, "Matched a regular Remote Pairing advertisement by its authentication tag. Full peer verification is still required.")
                    }
                    let reconnect = TCPTransport(endpoint: trustedEndpoint); self.activeTransport = reconnect
                    trustedClient = RemotePairingClient(transport: reconnect)
                    let verified = try await trustedClient.authenticate(endpoint: trustedEndpoint, service: self.service, existingRecord: authenticated, requestPIN: { throw TVPairError.authentication }, report: tunnelReconnectReporter(reporter))
                    if self.pendingRecord?.id == verified.id { self.pendingRecord = verified }
                    else if trustedEndpoint != endpoint {
                        do { self.saved = try await self.vault.save(verified) }
                        catch { self.pendingRecord = verified; self.storageError = TVPairError.safe(error).localizedDescription }
                    }
                }
                let tunnel = try await TrustedTunnel.establish(endpoint: trustedEndpoint, session: trustedClient, report: reporter)
                self.activeTransport = tunnel.transport
                try self.state.acceptTunnel(); self.log(.tunnel, .passed, "The authenticated TLS-PSK connection completed a valid CDTunnel handshake.")
                let developer = DeveloperConnection(tunnel: tunnel, hostIdentifier: authenticated.hostIdentifier, savedName: authenticated.deviceName)
                self.developerConnection = developer
                self.information = try await developer.inspect(report: reporter, updateInformation: { [weak self] value in await self?.receiveInformation(value) })
                try Task.checkCancellation(); try self.state.move(to: .finished)
                self.message = self.fullSuccess ? "Authentication, trusted tunnel, and a read-only developer-service request succeeded." : "The authenticated tunnel succeeded. Review the independent checks for developer-service limitations."
                if activationHost != nil {
                    self.activationMessage = self.fullSuccess ? "Developer access verified: the TV accepted pairing, the trusted tunnel opened, and a developer service responded." : "Pairing and the tunnel succeeded. Developer-service availability is not fully verified; review the independent checks."
                }
            } catch {
                let safe = TVPairError.safe(error), cancelled = safe == .cancelled || Task.isCancelled
                let failed = self.activeCheck ?? (self.state.authenticated ? .tunnel : .authentication)
                try? self.state.move(to: cancelled ? .cancelled : .failed)
                self.errorMessage = cancelled ? nil : safe.localizedDescription; self.message = cancelled ? "The connection attempt was cancelled." : safe.localizedDescription
                if activationHost != nil { self.activationMessage = self.state.authenticated ? "The TV accepted pairing, but developer access is not verified. " + self.message : self.message }
                self.log(failed, cancelled ? .cancelled : .failed, self.message, failure: safe)
            }
        }
    }
    func startHosting() {
        guard !busy && !processBusy else { return }
        finishPresentation(); busy = true; hosting = true; presentPairing = true; service = .pairableHost
        processResults = [:]; backboardResult = nil
        selectedDeviceSymbol = "network"
        tcpOnly = false
        checks = [:]; state = PairingState(); information = DeviceInformation(); errorMessage = nil; lastSavedID = nil
        pin = ""; hostPIN = nil; stageStart = [:]; activeCheck = nil
        discovery.start()
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.developerConnection == nil { self.activeTransport?.cancel() }
                self.activeTransport = nil; self.hostPIN = nil; self.busy = false; self.operation = nil
                if !self.state.authenticated { self.hostListener?.stop(); self.hostListener = nil; self.hosting = false }
                for check in DiagnosticCheck.allCases where self.checks[check] == nil || self.checks[check] == .running {
                    self.log(check, self.stage == .cancelled ? .cancelled : .blocked, "This check did not complete in this attempt.")
                }
            }
            do {
                let listener = PairableHostListener(identity: try PairableHostIdentity())
                self.hostListener = listener
                self.report(.advertising, .initiation, .running, "Publishing TVPair as a pairable host for iOS 27 / iPadOS 27 device-initiated pairing.")
                let incoming = try await listener.accept(onPublished: { [weak self] in await self?.hostWasPublished() })
                // The listener retains this control channel until the user dismisses
                // the result, because iOS Wi-Fi onboarding can be session-limited.
                let responder = PairableHostSession(transport: incoming, identity: listener.identity)
                let reporter: PairingReporter = { [weak self] stage, check, result, text in await self?.report(stage, check, result, text) }
                let record = try await responder.accept(displayPIN: { [weak self] code in await self?.showHostPIN(code) }, report: reporter)
                try Task.checkCancellation(); try self.state.acceptAuthentication()
                self.hostRecordID = record.id
                self.report(.persisting, .persistence, .running, "Saving the authenticated device-initiated pairing record.")
                do {
                    self.saved = try await self.vault.save(record); self.lastSavedID = record.id
                    self.log(.persistence, .passed, "Authenticated credentials were saved. Device-side Wi-Fi trust may be limited to the active onboarding session.")
                } catch {
                    self.pendingRecord = record; self.storageError = TVPairError.safe(error).localizedDescription
                    self.log(.persistence, .failed, "Credentials remain in memory for an explicit storage retry.", failure: TVPairError.safe(error))
                }
                self.report(.openingTunnel, .tunnel, .running, "Looking for the regular endpoint belonging to the authenticated device.")
                var endpoint: ConnectionEndpoint?
                for _ in 0..<24 {
                    endpoint = self.discovery.devices.first { $0.service == .remotePairing && $0.endpoint != nil && AdvertisementIdentity.matches(record: record, identifier: $0.advertisedIdentifier, authTag: $0.authenticationTag) }?.endpoint
                    if endpoint != nil { break }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard let endpoint else { throw TVPairError.unsupported("pairing authenticated, but no regular Remote Pairing advertisement matched the device's identity key. Keep the other device's pairing screen open, rescan, and reconnect with its saved record") }
                self.hostEndpoint = endpoint
                self.log(.discovery, .passed, "Discovered a regular service whose authentication tag matches the paired device.")
                let outgoing = TCPTransport(endpoint: endpoint); self.activeTransport = outgoing
                let client = RemotePairingClient(transport: outgoing)
                let verified = try await client.authenticate(endpoint: endpoint, service: .remotePairing, existingRecord: record, requestPIN: { throw TVPairError.authentication }, report: tunnelReconnectReporter(reporter))
                if self.pendingRecord?.id == verified.id { self.pendingRecord = verified }
                else {
                    do { self.saved = try await self.vault.save(verified) }
                    catch { self.pendingRecord = verified; self.storageError = TVPairError.safe(error).localizedDescription }
                }
                let tunnel = try await TrustedTunnel.establish(endpoint: endpoint, session: client, report: reporter)
                self.activeTransport = tunnel.transport
                try self.state.acceptTunnel(); self.log(.tunnel, .passed, "The authenticated TLS-PSK connection completed CDTunnel negotiation.")
                let developer = DeveloperConnection(tunnel: tunnel, hostIdentifier: verified.hostIdentifier, savedName: verified.deviceName)
                self.developerConnection = developer
                self.information = try await developer.inspect(report: reporter, updateInformation: { [weak self] info in await self?.receiveInformation(info) })
                try self.state.move(to: .finished)
                self.message = self.fullSuccess ? "Device-initiated pairing and the developer-service request succeeded." : "Device-initiated authentication completed. Review the remaining independent checks."
            } catch {
                let safe = TVPairError.safe(error), cancelled = safe == .cancelled || Task.isCancelled
                let failed = self.activeCheck ?? (self.state.authenticated ? .tunnel : .authentication)
                try? self.state.move(to: cancelled ? .cancelled : .failed)
                self.errorMessage = cancelled ? nil : safe.localizedDescription; self.message = cancelled ? "The incoming pairing attempt was cancelled." : safe.localizedDescription
                self.log(failed, cancelled ? .cancelled : .failed, self.message, failure: safe)
            }
        }
    }
    private func hostWasPublished() {
        guard busy, state.stage == .advertising else { return }
        report(.awaitingPeer, .initiation, .running, "TVPair is advertised. On the other iPhone or iPad (iOS 27+), open Settings → Developer → Paired Macs, select TVPair, then enter the code that appears here. Developer Mode alone is insufficient.")
    }
    private func showHostPIN(_ code: String?) { hostPIN = code }
    func retryHostedConnection() {
        guard canRetryHostedConnection, let endpoint = hostEndpoint, let id = hostRecordID else { return }
        start(endpoint: endpoint, service: .remotePairing, discovered: true, recordID: id)
    }
    func finishPresentation() {
        guard !busy && !processBusy else { return }
        developerConnection?.cancel(); developerConnection = nil
        hostListener?.stop(); hostListener = nil; hosting = false; hostPIN = nil; hostRecordID = nil; hostEndpoint = nil
    }
    func testProcess(_ app: ProcessTestApp, action: ProcessTestAction) {
        guard canTestProcesses, let developer = developerConnection else { return }
        processBusy = true; processResults[app] = "\(action.rawValue) test in progress…"
        processOperation = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            defer { self.processBusy = false; self.processOperation = nil }
            do {
                let result = try await developer.perform(app: app, action: action)
                let text = result.message(app: app, action: action)
                self.processResults[app] = text
                let status: CheckResult
                if case .acknowledged = result { status = .passed } else { status = .notAttempted }
                // Separate manual test: preserve the read-only availability check.
                self.append(DiagnosticEvent(operation: .services, service: self.service, result: status, message: "Manual \(action.rawValue.lowercased()) test: " + text, duration: Date().timeIntervalSince(started)))
            } catch {
                let safe = TVPairError.safe(error), cancelled = Task.isCancelled || safe == .cancelled
                let text = cancelled ? "Test cancelled. A request may already have reached the device. Reconnect to use Resume if needed." : safe.localizedDescription
                self.processResults[app] = text
                self.append(DiagnosticEvent(operation: .services, service: self.service, result: cancelled ? .cancelled : .failed, message: "Manual \(action.rawValue.lowercased()) test for \(app.rawValue): " + text, duration: Date().timeIntervalSince(started), failure: safe))
            }
        }
    }
    private func receiveInformation(_ value: DeviceInformation) { information = value }
    func killBackboard() {
        guard canTestProcesses, let developer = developerConnection else { return }
        processBusy = true; backboardResult = "Resolving BackBoard on the paired device…"
        processOperation = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            defer { self.processBusy = false; self.processOperation = nil }
            do {
                let result = try await developer.terminateBackboard()
                let text = result.message
                self.backboardResult = text
                let status: CheckResult
                if case .acknowledged = result { status = .passed } else { status = .notAttempted }
                self.append(DiagnosticEvent(operation: .services, service: self.service, result: status, message: "Manual BackBoard request: " + text, duration: Date().timeIntervalSince(started)))
            } catch {
                let safe = TVPairError.safe(error)
                let text = safe.localizedDescription + " The request may already have reached the device; a graphical-session restart can disconnect this session. Reconnect before another action."
                self.backboardResult = text
                self.append(DiagnosticEvent(operation: .services, service: self.service, result: Task.isCancelled ? .cancelled : .failed, message: "Manual BackBoard request: " + text, duration: Date().timeIntervalSince(started), failure: safe))
            }
        }
    }
    private func waitForPIN() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let requestID = UUID(); pinRequestID = requestID; pinContinuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard let self, self.pinContinuation != nil, self.pinRequestID == requestID else { return }
                    self.pinContinuation?.resume(throwing: TVPairError.timeout); self.pinContinuation = nil; self.pin = ""
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancelPIN() } }
    }
    private func cancelPIN() { pinContinuation?.resume(throwing: CancellationError()); pinContinuation = nil; pinRequestID = nil; pin = "" }
    func submitPIN() {
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
        let code = pin; pin = ""; pinContinuation?.resume(returning: code); pinContinuation = nil; pinRequestID = nil
    }
    func cancel() { activationTask?.cancel(); directProbe?.cancel(); operation?.cancel(); processOperation?.cancel(); developerConnection?.cancel(); developerConnection = nil; activeTransport?.cancel(); hostListener?.stop(); hostPIN = nil; cancelPIN() }
    func importRecord(_ url: URL) async {
        guard !busy else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 { throw TVPairError.invalidRecord("file exceeds one MiB") }
            let record = try PairingRecord.importPlist(Data(contentsOf: url))
            do { saved = try await vault.save(record) }
            catch { pendingRecord = record; storageError = TVPairError.safe(error).localizedDescription }
        } catch { errorMessage = TVPairError.safe(error).localizedDescription }
    }
    func exportRecord(_ id: UUID) async throws -> Data { try await vault.record(id: id).exportPlist() }
    func deleteRecord(_ id: UUID) async {
        do { saved = try await vault.delete(id: id) } catch { storageError = TVPairError.safe(error).localizedDescription }
    }
    var logs: String { "TVPair diagnostic export • no physical-device validation is implied\n" + LogSanitizer.export(events) }
}

private extension Optional {
    func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }; return try await transform(value)
    }
}
