import SwiftUI
import TVPairCore

struct DeviceDetailView: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String
    @ObservedObject var discovery: BonjourDiscovery
    private var device: AppleTVDevice? { discovery.devices.first { $0.id == deviceID } }
    var body: some View {
        List {
            if let device {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: device.systemImage).font(.system(size: 64)).foregroundStyle(.cyan)
                        Text(device.name).font(.title2.bold())
                        Text(device.identityLabel).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 22)
                }.listRowBackground(Color.clear)
                Section("Advertised endpoint") {
                    DetailRow(title: "Hostname", value: device.hostname)
                    DetailRow(title: "IP addresses", value: device.addresses.isEmpty ? nil : device.addresses.joined(separator: "\n"))
                    DetailRow(title: "Port", value: device.port > 0 ? String(device.port) : nil)
                    DetailRow(title: "Service", value: device.service.rawValue)
                    DetailRow(title: "Advertised model", value: device.advertisedModel)
                    DetailRow(title: "Status", value: "Discovered • unauthenticated")
                }
                Section {
                    if device.deviceFamily == .appleTV || (device.service.discoveryOnly && device.deviceFamily == .unknown) {
                        NavigationLink { AppleTVSetupView(discovery: discovery, initialHost: device.addresses.first(where: { !$0.contains(":") }) ?? device.addresses.first ?? "") } label: {
                            Label("Enable Apple TV developer access", systemImage: "appletv")
                        }
                    }
                    Button {
                        if let endpoint = device.endpoint { model.start(endpoint: endpoint, service: device.service, discovered: true, deviceID: device.id) }
                    } label: { Label(device.service.supportsNewPairing ? "Pair with this Apple TV" : "Test TCP connection", systemImage: "link") }
                    .disabled(device.endpoint == nil || model.busy)
                    if device.service.supportsPairing && !model.saved.isEmpty {
                        Menu {
                            ForEach(model.saved) { record in Button(record.name) {
                                if let endpoint = device.endpoint { model.start(endpoint: endpoint, service: device.service, discovered: true, recordID: record.id, deviceID: device.id) }
                            } }
                        } label: { Label("Reconnect with saved record", systemImage: "key.horizontal") }.disabled(device.endpoint == nil || model.busy)
                    }
                } footer: { Text(device.service.discoveryOnly ? "This is a discovery endpoint, not an RPPairing endpoint. A TCP test sends no pairing protocol. Find a separate Manual Remote Pairing advertisement to pair an Apple TV." : device.service == .remotePairing ? "This regular endpoint is for an existing pairing record. For a new iPhone/iPad pairing, use Pair with iPhone / iPad on Devices (iOS 27+). For Apple TV, open Remote App and Devices and select its separate Manual Remote Pairing service." : "Apple TV manual pairing displays a code on the TV. The regular Remote Pairing endpoint is used afterward with the saved record.") }
            } else {
                ContentUnavailableView("Service no longer available", systemImage: "wifi.slash", description: Text("Return to Devices and wait for a current advertisement. Start scanning again if it was stopped."))
            }
            Section {
                if let test = model.serviceTests[deviceID] {
                    DetailRow(title: "Tested endpoint", value: test.endpoint.description)
                    DetailRow(title: "Tested service", value: test.service.rawValue)
                    Text(test.finishedAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                    Text(test.message).font(.footnote).foregroundStyle(.secondary)
                    CheckList(checks: test.checks)
                } else {
                    Text("No test has completed for this service in this app session.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Latest test for this service") } footer: {
                Text("Tests of other services and manually selected protocols are separate. A successful TCP-only test does not attempt pairing.")
            }
        }.navigationTitle("Device details").navigationBarTitleDisplayMode(.inline)
    }
}

struct DetailRow: View {
    let title: String
    let value: String?
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "Unavailable").multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline).padding(.vertical, 2)
    }
}

struct AppleTVSetupView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var discovery: BonjourDiscovery
    var initialHost = ""
    @State private var manual = false
    @State private var developerIP = ""
    private var pairingServices: [AppleTVDevice] { discovery.devices.filter { $0.service == .manualPairing } }
    var body: some View {
        List {
            Section {
                TextField("Apple TV IP address", text: $developerIP).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .disabled(model.busy || model.processBusy)
                Button { model.enableAppleTVDeveloperAccess(host: developerIP) } label: {
                    Label("Enable developer access", systemImage: "hammer")
                }.disabled(model.busy || model.processBusy || developerIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.activationBusy {
                    ProgressView("Contacting the selected TV…")
                    Button("Cancel developer setup", role: .cancel) { model.cancel() }
                }
                if let status = model.activationMessage { Text(status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: { Text("Developer setup from this phone") } footer: {
                Text("Requests developer trust through the TV's displayed code, then verifies the tunnel and developer service. The IP can be taken from the TV's AirPlay or Companion discovery row; its port is resolved separately. Keep the TV on its pairing screen. Approval and code entry are required.")
            }
            Section("Prepare the TV") {
                Label("Keep the TV awake on the same local network.", systemImage: "wifi")
                Text("On Apple TV, open Settings → Remotes and Devices → Remote App and Devices. Keep this screen open while scanning and pairing.")
                Text("Developer setup establishes trust with this phone acting as a developer host. Developer Settings visibility on the TV is not treated as verified until you check it; TVPair verifies access with an actual developer-service request.").font(.footnote).foregroundStyle(.secondary)
                Link("Apple's Developer Mode documentation", destination: URL(string: "https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device")!)
            }
            Section {
                Button(discovery.scanning ? "Restart service scan" : "Scan for services") { discovery.start() }.disabled(model.busy)
                if let message = discovery.discoveryMessage {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if pairingServices.isEmpty {
                    Text("No Manual Remote Pairing advertisement found yet.").foregroundStyle(.secondary)
                }
                ForEach(pairingServices) { device in
                    Button {
                        if let endpoint = device.endpoint { model.start(endpoint: endpoint, service: .manualPairing, discovered: true, deviceID: device.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(device.name, systemImage: device.systemImage)
                            Text(device.endpoint?.description ?? "Resolving…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.disabled(device.endpoint == nil || model.busy || model.processBusy)
                }
            } header: { Text("Find the developer pairing service") } footer: {
                Text("TVPair requests the code only after a valid Apple TV handshake. Enter the code displayed on the TV when prompted. A discovered name or icon does not establish device identity.")
            }
            Section("If you see only AirPlay or Companion") {
                Text("These services help locate the TV and its address, but their ports do not accept developer pairing. An open TCP port alone is insufficient.")
                Button("Enter IP and actual pairing port…") { manual = true }.disabled(model.busy || model.processBusy)
                Text("The manual port must come from this TV's Manual Remote Pairing advertisement. Port 49152 on another device is not a default for this TV. TVPair does not guess a port or reuse the AirPlay port.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Direct setup in LiveContainer") {
                Text("The action above sends a targeted DNS query to this TV and then connects to its returned pairing port. It does not modify or replace LiveContainer. Local Network access is still required. If the TV does not answer this query, setup stops; an open AirPlay port alone is not developer access.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Other iPhones and iPads") {
                Text("This scan lists supported advertisements, not every device on Wi-Fi. An iPad with no supported service enabled may remain absent. AirPlay/Companion discovery does not require developer pairing, but does not grant developer access.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Apple TV setup").navigationBarTitleDisplayMode(.inline)
        .onAppear { if developerIP.isEmpty { developerIP = initialHost } }
        .sheet(isPresented: $manual) { ManualConnectionView(initialHost: initialHost) }
    }
}

struct SavedRecordView: View {
    @EnvironmentObject private var model: AppModel
    let record: SavedDevice
    @State private var exportWarning = false
    @State private var deleteWarning = false
    @State private var share: ShareItem?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("Saved credentials") {
                DetailRow(title: "Name", value: record.name)
                DetailRow(title: "Device identifier", value: record.identifier)
                DetailRow(title: "Product type", value: record.productType)
                DetailRow(title: "Pairing date", value: record.pairedAt?.formatted(date: .abbreviated, time: .shortened))
                DetailRow(title: "Import date", value: record.importedAt?.formatted(date: .abbreviated, time: .shortened))
                DetailRow(title: "Last endpoint", value: record.endpoint?.description)
                DetailRow(title: "Status", value: "Credentials saved • reconnect to verify")
            }
            Section {
                if let endpoint = record.endpoint {
                    Button("Reconnect to last endpoint") { model.start(endpoint: endpoint, service: .remotePairing, discovered: false, recordID: record.id) }.disabled(model.busy || !record.canVerifyPeer)
                }
                if !record.canVerifyPeer {
                    Text("This imported format has no pinned peer signing key. It is stored and exportable, but TVPair requires a new PIN pairing before it can authenticate the peer.").font(.footnote).foregroundStyle(.orange)
                }
                Text("For a changed address or a manual-pairing port, select a current Remote Pairing advertisement under Devices and choose Reconnect with saved record.").font(.footnote).foregroundStyle(.secondary)
                Button { exportWarning = true } label: { Label("Export pairing record…", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { deleteWarning = true } label: { Label("Delete saved credentials", systemImage: "trash") }.disabled(model.busy)
            }
        }.navigationTitle(record.name).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Export sensitive credentials?", isPresented: $exportWarning, titleVisibility: .visible) {
            Button("Export private pairing record") {
                Task {
                    do { share = try ShareItem(data: await model.exportRecord(record.id), name: "TVPair-\(record.id.uuidString).plist", sensitive: true) }
                    catch { model.errorMessage = TVPairError.safe(error).localizedDescription }
                }
            }
        } message: { Text("This file contains a private signing key and pairing credentials. Share it only with a destination you trust. It will leave TVPair's protected storage.") }
        .confirmationDialog("Delete this record?", isPresented: $deleteWarning, titleVisibility: .visible) {
            Button("Delete credentials", role: .destructive) { Task { await model.deleteRecord(record.id); if !model.saved.contains(where: { $0.id == record.id }) { dismiss() } } }
        } message: { Text("This removes the local record. It does not revoke trust on Apple TV. Remove the paired host on Apple TV separately to revoke access.") }
        .sheet(item: $share, onDismiss: { ShareItem.cleanup() }) { ActivitySheet(url: $0.url) }
    }
}
