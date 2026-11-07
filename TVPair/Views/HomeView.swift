import SwiftUI
import UniformTypeIdentifiers
import TVPairCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        TabView {
            NavigationStack { HomeView(discovery: model.discovery) }.tabItem { Label("Devices", systemImage: "appletv") }
            NavigationStack { DiagnosticsView() }.tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .tint(.cyan)
        .sheet(isPresented: $model.presentPairing, onDismiss: { model.finishPresentation() }) { PairingView().environmentObject(model).interactiveDismissDisabled(model.busy) }
        .alert("TVPair", isPresented: Binding(get: { model.errorMessage != nil && !model.presentPairing }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var discovery: BonjourDiscovery
    @State private var manual = false
    @State private var importing = false
    @State private var confirmStorage = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "appletv.fill").font(.system(size: 38)).foregroundStyle(.cyan).frame(width: 66, height: 66).background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TVPair").font(.largeTitle.bold())
                        Text("Local network pairing lab").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8).listRowBackground(Color.clear)
                Label(discovery.networkStatus, systemImage: "wifi").font(.footnote)
                Text("Experimental native client. Authentication and developer access are tested independently. No VPN is required to launch or scan.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { discovery.scanning ? discovery.stop() : discovery.start() } label: {
                    HStack {
                        Label(discovery.scanning ? "Stop scanning" : "Scan local network", systemImage: discovery.scanning ? "stop.circle" : "antenna.radiowaves.left.and.right")
                        Spacer(); if discovery.scanning { ProgressView().controlSize(.small) }
                    }
                }
                if let error = discovery.discoveryMessage {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                    if discovery.offerNetworkSettings {
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }
                }
                if discovery.devices.isEmpty {
                    ContentUnavailableView(discovery.scanning ? "Listening for services" : "Find your Apple TV", systemImage: "appletv", description: Text("Use the same Wi-Fi. On Apple TV, open Settings → Remotes and Devices → Remote App and Devices. A service advertisement alone does not verify device identity."))
                } else {
                    ForEach(discovery.devices) { device in
                        NavigationLink { DeviceDetailView(deviceID: device.id, discovery: discovery) } label: { DeviceCard(device: device) }
                    }
                }
            } header: { Text("Discovered services • \(discovery.devices.count)") } footer: { Text("A device can advertise multiple endpoints. Lockdown endpoints support a TCP test only.") }
            Section("Connect directly") {
                Button { manual = true } label: { Label("Enter IP address or hostname", systemImage: "network") }
            }
            Section {
                Button { model.startHosting() } label: { Label("Pair with iPhone / iPad", systemImage: "iphone.radiowaves.left.and.right") }.disabled(model.busy)
                Text("Requires iOS 27 / iPadOS 27 on the other device. Select TVPair in its Settings → Developer → Paired Macs screen, then enter the code displayed by TVPair. A regular Remote Pairing advertisement alone cannot create new trust.").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Device-initiated pairing") }
            Section {
                if model.saved.isEmpty { Text("No saved pairing records").foregroundStyle(.secondary) }
                ForEach(model.saved) { record in NavigationLink { SavedRecordView(record: record) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(record.name, systemImage: "key.horizontal").font(.headline)
                        Text(record.importedAt == nil ? "Saved credentials • reconnect to verify" : "Imported credentials • unverified").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                } }
                Button { importing = true } label: { Label("Import Remote Pairing record", systemImage: "square.and.arrow.down") }.disabled(model.busy)
            } header: { Text("Saved devices") } footer: { Text(model.fileStorage ? "Storage: protected app-container file. Credentials are available to the hosting container while unlocked." : "Storage: Keychain, available while unlocked on this device.") }
            if let error = model.storageError {
                Section("Credential storage needs attention") {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                    Button("Retry selected storage") { Task { await model.retryStorage() } }
                    if !model.fileStorage { Button("Use protected file storage…") { confirmStorage = true } }
                }
            }
            Section {
                NavigationLink("Open-source licenses") { AttributionView() }
                Text("TVPair • build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unavailable")").font(.caption).foregroundStyle(.secondary)
                Text("Experimental protocol client. Trusted tunnels and developer-service access still require physical validation on each target and LiveContainer setup.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Devices").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $manual) { ManualConnectionView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { Task { await model.importRecord(url) } }
        }
        .confirmationDialog("Use protected file storage?", isPresented: $confirmStorage, titleVisibility: .visible) {
            Button("Use protected app-container file") { Task { await model.enableProtectedStorage() } }
        } message: { Text("This explicitly changes storage for future saves. iOS complete file protection and backup exclusion will be applied. The LiveContainer host may access the guest container. Existing Keychain records remain in their separate vault.") }
    }
}

private struct AttributionView: View {
    var body: some View {
        ScrollView {
            Text(notices).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle("Licenses")
    }
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "License notices are unavailable in this build. See the repository's THIRD_PARTY_NOTICES.md." }
        return text
    }
}

struct DeviceCard: View {
    let device: AppleTVDevice
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "appletv.fill").font(.title2).foregroundStyle(.cyan).frame(width: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.headline)
                Text(device.endpoint?.description ?? (device.resolutionError ? "Resolution failed" : "Resolving…")).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(device.service.title).font(.caption).foregroundStyle(.cyan)
                Text("Discovered • unauthenticated").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 7)
    }
}

struct ManualConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var kind = ServiceKind.manualPairing
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    TextField("IP address or hostname", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Advertised port", text: $port).keyboardType(.numberPad)
                    Picker("Protocol", selection: $kind) { ForEach(ServiceKind.browsed, id: \.self) { Text($0.title).tag($0) } }
                }
                Text("Enter the actual service port; ports may change. IPv6 link-local addresses require an interface scope (for example fe80::1%en0). The selected protocol is a user-supplied hint until its handshake is validated.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
                Button(kind.supportsNewPairing ? "Attempt Apple TV pairing" : "Test TCP connection") {
                    do { let endpoint = try ConnectionEndpoint(host: host, port: port); dismiss(); Task { @MainActor in
                        // Allow the manual sheet to dismiss before presenting the progress sheet.
                        try? await Task.sleep(for: .milliseconds(350)); model.start(endpoint: endpoint, service: kind, discovered: false)
                    } } catch { self.error = TVPairError.safe(error).localizedDescription }
                }.disabled(model.busy)
            }.navigationTitle("Manual connection").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
