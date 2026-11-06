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
        if busy { return stage == .awaitingPIN ? "Enter the Apple TV code" : "Testing the connection" }
        if fullSuccess { return "Developer connection verified" }
        if state.authenticated { return state.trustedTunnel ? "Authenticated tunnel verified" : "Pairing authenticated • tunnel unverified" }
        if stage == .cancelled { return "Connection cancelled" }
        return "Connection not authenticated"
    }
    init() {
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
            if let pendingRecord { saved = try await vault.save(pendingRecord); lastSavedID = pendingRecord.id; self.pendingRecord = nil; log(.persistence, .passed, "Saved the pending authenticated record.") }
            else { saved = try await vault.load() }
            storageError = nil
        } catch { storageError = TVPairError.safe(error).localizedDescription }
    }
    func append(_ event: DiagnosticEvent) { events.append(event); if events.count > 1000 { events.removeFirst(events.count - 1000) } }
    private func log(_ check: DiagnosticCheck, _ result: CheckResult, _ text: String) {
        checks[check] = result
        if result == .running { stageStart[check] = Date(); activeCheck = check }
        else if activeCheck == check { activeCheck = nil }
        append(DiagnosticEvent(operation: check, service: service, result: result, message: text, duration: stageStart[check].map { Date().timeIntervalSince($0) } ?? 0))
    }
    private func report(_ stage: PairingStage, _ check: DiagnosticCheck, _ result: CheckResult, _ text: String) {
        do { if stage != state.stage { try state.move(to: stage) } }
        catch { errorMessage = TVPairError.safe(error).localizedDescription }
        message = text; log(check, result, text)
    }
    func start(endpoint: ConnectionEndpoint, service: ServiceKind, discovered: Bool, recordID: UUID? = nil) {
        guard !busy else { return }
        busy = true; presentPairing = true; self.service = service; checks = [:]; state = PairingState()
        information = DeviceInformation(); errorMessage = nil; lastSavedID = nil; pin = ""; started = Date(); stageStart = [:]; activeCheck = nil
        log(.discovery, discovered ? .passed : .blocked, discovered ? "Selected a currently discovered service." : "Manual endpoint; Bonjour discovery was bypassed.")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.activeTransport?.cancel(); self.activeTransport = nil; self.busy = false
                self.pinContinuation?.resume(throwing: CancellationError()); self.pinContinuation = nil; self.pin = ""
                for check in DiagnosticCheck.allCases where self.checks[check] == nil || self.checks[check] == .running {
                    self.log(check, self.stage == .cancelled ? .cancelled : .blocked, "This check did not complete in this attempt.")
                }
                self.operation = nil
            }
            do {
                let transport = TCPTransport(endpoint: endpoint); self.activeTransport = transport
                if !service.supportsPairing {
                    self.report(.connecting, .tcp, .running, "Testing TCP only for this service type.")
                    try await transport.connect(timeout: 10)
                    self.log(.resolution, .passed, "Endpoint resolved as part of the TCP connection.")
                    self.log(.tcp, .passed, "TCP connected. No pairing protocol was sent to this service.")
                    self.log(.initiation, .blocked, "Lockdown and RSD advertisements are not interchangeable with RPPairing endpoints.")
                    try self.state.move(to: .finished); self.message = "TCP test completed. Authentication was not attempted."; return
                }
                let record = try await recordID.mapAsync { try await self.vault.record(id: $0) }
                let client = RemotePairingClient(transport: transport)
                let reporter: PairingReporter = { [weak self] stage, check, result, message in
                    await self?.report(stage, check, result, message)
                }
                let authenticated = try await client.authenticate(endpoint: endpoint, existingRecord: record, requestPIN: { [weak self] in
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
                    self.log(.persistence, .failed, "Credential persistence failed. The record remains in memory for an explicit retry during this app session.")
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
                    _ = try await trustedClient.authenticate(endpoint: trustedEndpoint, existingRecord: authenticated, requestPIN: { throw TVPairError.authentication }, report: { [weak self] _, check, result, text in
                        await self?.report(.openingTunnel, check, result, text)
                    })
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
                self.log(failed, cancelled ? .cancelled : .failed, self.message)
            }
        }
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
    func cancel() { operation?.cancel(); activeTransport?.cancel(); cancelPIN() }
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
