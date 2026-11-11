import SwiftUI

/// The raw Bluetooth conversation of one meter, for reporting back what a device actually does. The 1587 FC's
/// GATT table hasn't been published anywhere, so this is how it gets confirmed (or corrected).
struct DiagnosticsView: View {
    let meter: FlukeMeter
    @AppStorage(Pref.watchExtras) private var watchExtras = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Everything the app sees from \(meter.name): the services the device offers and each reading's raw bytes. The only thing the app writes is its one-byte connection ID.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meter.logText, forType: .string)
                }
                Button("Show File") { DiagnosticsFile.reveal() }
                    .help("Show the full log file, which keeps everything since launch (all meters, each line marked with its ID#)")
                Button("Clear") { meter.clearLog() }
            }
            Toggle("Also watch the meter's undocumented state characteristics (takes effect on the next connection)", isOn: $watchExtras)
                .font(.callout)
                .help("Logs every change on them. Only useful for investigating; it adds a little traffic to the meter.")
            ScrollView {
                Text(meter.log.isEmpty ? String(localized: "Nothing yet.") : meter.logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        }
    }
}
