import SwiftUI
import TVPairCore

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var pinFocused: Bool
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 18) {
                        ZStack {
                            Circle().fill(.cyan.opacity(0.1)).frame(width: 112, height: 112)
                            Image(systemName: model.fullSuccess ? "checkmark.shield.fill" : "appletv.fill").font(.system(size: 47)).foregroundStyle(model.fullSuccess ? .green : .cyan)
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
                    Section { Text("iPhone Wi-Fi onboarding may last only while this host session remains open. Closing this result stops the host; saved credentials do not guarantee that the other device retains trust.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Independent checks") { CheckList(checks: model.checks) }
                if model.state.authenticated {
                    Section("Authenticated device information") {
                        DetailRow(title: "Name", value: model.information.name)
                        DetailRow(title: "Identifier", value: model.information.identifier)
                        DetailRow(title: "Product type", value: model.information.productType)
                        DetailRow(title: "tvOS version", value: model.information.osVersion)
                    }
                    if !model.information.developerServices.isEmpty {
                        Section("Advertised developer services") {
                            ForEach(model.information.developerServices, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                    }
                }
                if let error = model.storageError { Section("Storage") { Text(error).font(.footnote).foregroundStyle(.orange) } }
                if let id = model.lastSavedID, let record = model.saved.first(where: { $0.id == id }) {
                    Section { NavigationLink("View or export saved record") { SavedRecordView(record: record) } }
                }
            }
            .navigationTitle("Connection test").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(model.busy ? "Cancel" : "Done") { if model.busy { model.cancel() } else { model.finishPresentation(); dismiss() } }
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
        case .blocked: return "minus.circle"
        case .cancelled: return "stop.circle"
        default: return "circle.dotted"
        }
    }
    private func color(_ result: CheckResult) -> Color {
        switch result { case .passed: return .green; case .failed: return .orange; case .running: return .cyan; default: return .secondary }
    }
}
