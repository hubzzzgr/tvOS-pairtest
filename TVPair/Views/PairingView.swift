import SwiftUI
import TVPairCore

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pinFocused: Bool
    @State private var confirmBackboard = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 18) {
                        ZStack {
                            Circle().fill(.cyan.opacity(0.1)).frame(width: 112, height: 112)
                            Image(systemName: model.fullSuccess ? "checkmark.shield.fill" : model.tcpOnly ? "network" : "appletv.fill").font(.system(size: 47)).foregroundStyle(model.fullSuccess || (model.tcpOnly && model.stage == .finished) ? .green : .cyan)
                        }
                        Text(model.summary).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(model.message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if model.busy && model.stage != .awaitingPIN && model.stage != .displayingPIN { ProgressView() }
                    }.frame(maxWidth: .infinity).padding(.vertical, 20)
                }.listRowBackground(Color.clear)
                if model.stage == .awaitingPIN && model.busy {
                    Section {
                        SecureField("Six-digit code", text: $model.pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .font(.title.monospaced()).focused($pinFocused).onAppear { pinFocused = true }
                            .onChange(of: model.pin) { _, value in model.pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                        Button("Authenticate") { pinFocused = false; model.submitPIN() }.disabled(model.pin.count != 6)
                    } header: { Text("Code displayed on Apple TV") } footer: { Text("The protocol requested this code. It is never saved or included in diagnostic logs. Entry times out after 90 seconds.") }
                }
                if let code = model.hostPIN, model.stage == .displayingPIN, model.busy {
                    Section {
                        Text(code).font(.system(size: 40, weight: .semibold, design: .monospaced)).frame(maxWidth: .infinity).privacySensitive()
                        Text("Enter this code on the OTHER iPhone or iPad. Keep this app and the other device's pairing screen open. The code expires after 90 seconds.").font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Code for the other device") }
                }
                if model.hosting {
                    Section {
                        Text("iPhone Wi-Fi onboarding may last only while this host session remains open. Closing this result stops the host; saved credentials do not guarantee that the other device retains trust.").font(.footnote).foregroundStyle(.secondary)
                        if model.canRetryHostedConnection {
                            Button("Retry saved-record connection") { model.retryHostedConnection() }
                        }
                    }
                }
                Section("Independent checks") { CheckList(checks: model.checks) }
                if model.state.authenticated {
                    Section("Authenticated device information") {
                        DetailRow(title: "Name", value: model.information.name)
                        if model.information.name != nil { DetailRow(title: "Name source", value: model.information.nameSource) }
                        DetailRow(title: "Identifier", value: model.information.identifier)
                        DetailRow(title: "Product type", value: model.information.productType)
                        DetailRow(title: "OS version", value: model.information.osVersion)
                    }
                    Section {
                        Text(model.information.developerServiceDetail).font(.footnote).foregroundStyle(.secondary)
                    } header: { Text("Developer-service result") }
                    if !model.information.developerServices.isEmpty {
                        Section("Advertised developer services") {
                            ForEach(model.information.developerServices, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                    }
                    if model.state.trustedTunnel {
                        Section {
                            ForEach(ProcessTestApp.allCases) { app in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(app.rawValue).font(.headline)
                                    HStack {
                                        Button { model.testProcess(app, action: .pause) } label: { Label("Pause", systemImage: "pause.fill") }
                                        Spacer()
                                        Button { model.testProcess(app, action: .resume) } label: { Label("Resume", systemImage: "play.fill") }
                                    }.buttonStyle(.bordered).disabled(!model.canTestProcesses)
                                    if let text = model.processResults[app] { Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                                }.padding(.vertical, 4)
                            }
                            if model.processBusy { ProgressView("Waiting for the paired device…") }
                            if !model.information.instrumentsServiceResponded {
                                Text("Pause/resume requires the Instruments hub to pass its read-only probe. See the developer-service result above.").font(.footnote).foregroundStyle(.orange)
                            }
                        } header: { Text("App pause / resume test") } footer: {
                            Text("Open the target app on the OTHER device first. iOS may deny suspension of App Store apps. An acknowledgement confirms the request, not a verified frozen state. Use Resume to undo a pause; closing this screen does not resume the app.")
                        }
                        Section {
                            Button(role: .destructive) { confirmBackboard = true } label: {
                                Label("Kill BackBoard…", systemImage: "power")
                            }.disabled(!model.canTestProcesses)
                            if let text = model.backboardResult {
                                Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        } header: { Text("Paired device — BackBoard") } footer: {
                            Text("Attempts to terminate backboardd on the paired device. This may restart its graphical session and disconnect the tunnel. Requires the Instruments probe to pass; iOS may deny the request.")
                        }
                    }
                }
                if let error = model.storageError { Section("Storage") { Text(error).font(.footnote).foregroundStyle(.orange) } }
                if let id = model.lastSavedID, let record = model.saved.first(where: { $0.id == id }) {
                    Section { NavigationLink("View or export saved record") { SavedRecordView(record: record) } }
                }
            }
            .navigationTitle("Connection test").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Kill BackBoard on the paired device?", isPresented: $confirmBackboard, titleVisibility: .visible) {
                Button("Kill BackBoard", role: .destructive) { model.killBackboard() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This sends a termination request to backboardd on the paired device. Its graphical session may restart and this connection may close. Unsaved work may be lost.")
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(model.busy || model.processBusy ? "Cancel" : "Done") { if model.busy || model.processBusy { model.cancel() } else { model.finishPresentation(); dismiss() } }
            } }
        }
    }
}

struct CheckList: View {
    let checks: [DiagnosticCheck: CheckResult]
    var body: some View {
        ForEach(DiagnosticCheck.allCases, id: \.self) { check in
            let result = checks[check] ?? .pending
            HStack(spacing: 10) {
                if result == .running { ProgressView().controlSize(.small).frame(width: 22) }
                else { Image(systemName: icon(result)).foregroundStyle(color(result)).frame(width: 22) }
                Text(check.rawValue).font(.subheadline)
                Spacer()
                Text(result.rawValue.capitalized).font(.caption).foregroundStyle(color(result))
            }.padding(.vertical, 3)
        }
    }
    private func icon(_ result: CheckResult) -> String {
        switch result {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .blocked, .notAttempted: return "minus.circle"
        case .cancelled: return "stop.circle"
        default: return "circle.dotted"
        }
    }
    private func color(_ result: CheckResult) -> Color {
        switch result { case .passed: return .green; case .failed: return .orange; case .running: return .cyan; default: return .secondary }
    }
}
