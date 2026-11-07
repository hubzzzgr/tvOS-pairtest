import SwiftUI
import TVPairCore

@MainActor
final class AppModel: ObservableObject {
    let discovery = BonjourDiscovery()
    private let vault = CredentialVault()
    @Published var saved: [SavedDevice] = []
    @Published var events: [DiagnosticEvent] = []
    @Published var checks: [DiagnosticCheck: CheckResult] = [:]
    @Published var state = PairingState()
    @Published var busy = false
    @Published var presentPairing = false
    @Published var message = "Select an advertised service or enter an endpoint."
    @Published var errorMessage: String?
    @Published var storageError: String?
    @Published var fileStorage = UserDefaults.standard.bool(forKey: "TVPair.protectedFileStorage")
    @Published var pin = ""
    @Published var information = DeviceInformation()
    @Published private(set) var hostPIN: String?
    @Published private(set) var hosting = false
    @Published private(set) var tcpOnly = false
    private var hostListener: PairableHostListener?
    private var hostRecordID: UUID?
    private var hostEndpoint: ConnectionEndpoint?
    var canRetryHostedConnection: Bool {
        !busy && hosting && hostEndpoint != nil && saved.contains { $0.id == hostRecordID }
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
    func start(endpoint: ConnectionEndpoint, service: ServiceKind, discovered: Bool, recordID: UUID? = nil) {
        guard !busy else { return }
        // A retry for this onboarding record must not tear down the channel
        // that may be keeping the other iPhone's session-limited trust alive.
        if !(hosting && recordID != nil && recordID == hostRecordID) { finishPresentation() }
        busy = true; presentPairing = true; self.service = service; checks = [:]; state = PairingState()
        tcpOnly = !service.supportsPairing || (recordID == nil && !service.supportsNewPairing)
        information = DeviceInformation(); errorMessage = nil; lastSavedID = nil; pin = ""; started = Date(); stageStart = [:]; activeCheck = nil
        log(.discovery, discovered ? .passed : .blocked, discovered ? "Selected a currently discovered service." : "Manual endpoint; Bonjour discovery was bypassed.")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeTransport?.cancel(); self.activeTransport = nil; self.busy = false
                self.pinContinuation?.resume(throwing: CancellationError()); self.pinContinuation = nil; self.pin = ""
                for check in DiagnosticCheck.allCases where self.checks[check] == nil || self.checks[check] == .running {
                    let skipped = self.tcpOnly && ![DiagnosticCheck.discovery, .resolution, .tcp].contains(check)
                    self.log(check, skipped ? .notAttempted : self.stage == .cancelled ? .cancelled : .blocked, skipped ? "This check is outside the selected TCP-only test." : "This check did not complete in this attempt.")
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
                    self.log(.initiation, .notAttempted, service == .remotePairing ? "This regular Remote Pairing endpoint requires a saved record. For an iPhone or iPad, use Pair with iPhone / iPad on Devices and start pairing from the other device's Paired Macs screen (iOS 27+). Apple TV uses its separate Manual Remote Pairing service." : "Lockdown and RSD advertisements are not interchangeable with RPPairing endpoints.")
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
                    if service == .manualPairing, let regular = self.discovery.devices.first(where: {
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
                let tunnel = try await TrustedTunnel.establish(endpoint: trustedEndpoint, session: trustedClient)
                self.activeTransport = tunnel.transport
                try self.state.acceptTunnel(); self.log(.tunnel, .passed, "The authenticated TLS-PSK connection completed a valid CDTunnel handshake.")
                self.information = try await DeveloperServiceClient.inspect(tunnel: tunnel, hostIdentifier: authenticated.hostIdentifier, report: reporter, updateInformation: { [weak self] value in await self?.receiveInformation(value) })
                try Task.checkCancellation(); try self.state.move(to: .finished)
                self.message = self.fullSuccess ? "Authentication, trusted tunnel, and a read-only developer-service request succeeded." : "The authenticated tunnel succeeded. Review the independent checks for developer-service limitations."
            } catch {
                let safe = TVPairError.safe(error), cancelled = safe == .cancelled || Task.isCancelled
                let failed = self.activeCheck ?? (self.state.authenticated ? .tunnel : .authentication)
                try? self.state.move(to: cancelled ? .cancelled : .failed)
                self.errorMessage = cancelled ? nil : safe.localizedDescription; self.message = cancelled ? "The connection attempt was cancelled." : safe.localizedDescription
                self.log(failed, cancelled ? .cancelled : .failed, self.message, failure: safe)
            }
        }
    }
    func startHosting() {
        guard !busy else { return }
        finishPresentation(); busy = true; hosting = true; presentPairing = true; service = .pairableHost
        tcpOnly = false
        checks = [:]; state = PairingState(); information = DeviceInformation(); errorMessage = nil; lastSavedID = nil
        pin = ""; hostPIN = nil; stageStart = [:]; activeCheck = nil
        discovery.start()
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeTransport?.cancel(); self.activeTransport = nil; self.hostPIN = nil; self.busy = false; self.operation = nil
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
                let tunnel = try await TrustedTunnel.establish(endpoint: endpoint, session: client)
                self.activeTransport = tunnel.transport
                try self.state.acceptTunnel(); self.log(.tunnel, .passed, "The authenticated TLS-PSK connection completed CDTunnel negotiation.")
                self.information = try await DeveloperServiceClient.inspect(tunnel: tunnel, hostIdentifier: verified.hostIdentifier, report: reporter, updateInformation: { [weak self] info in await self?.receiveInformation(info) })
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
        guard !busy else { return }
        hostListener?.stop(); hostListener = nil; hosting = false; hostPIN = nil; hostRecordID = nil; hostEndpoint = nil
    }
    private func receiveInformation(_ value: DeviceInformation) { information = value }
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
    func cancel() { operation?.cancel(); activeTransport?.cancel(); hostListener?.stop(); hostPIN = nil; cancelPIN() }
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
