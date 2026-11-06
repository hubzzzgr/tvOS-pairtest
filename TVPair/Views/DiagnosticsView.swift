import SwiftUI
import TVPairCore

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var share: ShareItem?
    @State private var copied = false
    var body: some View {
        List {
            Section("Latest attempt") { CheckList(checks: model.checks) }
            Section {
                Button { UIPasteboard.general.string = model.logs; copied = true } label: { Label(copied ? "Copied sanitized logs" : "Copy sanitized logs", systemImage: "doc.on.doc") }
                Button {
                    do { share = try ShareItem(data: Data(model.logs.utf8), name: "TVPair-diagnostics.txt", sensitive: false) }
                    catch { model.errorMessage = "Could not prepare the diagnostic export." }
                } label: { Label("Export sanitized logs", systemImage: "square.and.arrow.up") }
                Button("Clear logs", role: .destructive) { model.events.removeAll() }.disabled(model.busy)
            } footer: { Text("Protocol payloads, keys, PINs, tokens and pairing records are never added to the log. Exports apply additional redaction. Up to 1,000 events are held in memory.") }
            Section("Activity") {
                if model.events.isEmpty { Text("No diagnostic events yet").foregroundStyle(.secondary) }
                ForEach(model.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(event.operation.rawValue).font(.subheadline.bold())
                            Spacer(); Text(event.result.rawValue).font(.caption).foregroundStyle(event.result == .failed ? .orange : .secondary)
                        }
                        Text(event.message).font(.caption).textSelection(.enabled)
                        if let code = event.errorCode { Text("\(event.errorDomain ?? "Error") code \(String(code))").font(.caption.monospaced()).foregroundStyle(.orange) }
                        Text("\(event.timestamp.formatted(date: .omitted, time: .standard)) • \(event.service.rawValue) • \(String(format: "%.3f s", event.duration))").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("Diagnostics")
        .sheet(item: $share, onDismiss: { ShareItem.cleanup() }) { ActivitySheet(url: $0.url) }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    private static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("TVPair-exports", isDirectory: true) }
    init(data: Data, name: String, sensitive: Bool) throws {
        Self.cleanup()
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        url = Self.directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        var dir = Self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try dir.setResourceValues(values)
    }
    static func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
