import AppKit
import FlukeCore
import Foundation

// Hardware probe, for checking a real meter without looking at the UI (it does what the app does: it
// writes only the one-byte connection ID):
//
//   open -n "Fluke FC Control.app" --args --probe /path/to/report.txt
//
// Scans for ~25 s, then connects to the strongest device that looks like a Fluke Connect device,
// listens for ~75 s, writes everything to the report file and quits. Nothing is saved and nothing
// else is ever written to a device. Launch the bundle with `open -n` (not from a shell) so the
// Bluetooth permission is attributed to the app.
extension FlukeHub {
    func startProbeIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--probe"), i + 1 < args.count else { return }
        isProbe = true
        let path = args[i + 1]
        Task { await runProbe(reportPath: path) }
    }

    private func runProbe(reportPath: String) async {
        var report = ["Fluke FC Control probe, \(Date().formatted(.iso8601))"]
        func finish() {
            try? report.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        // Wait for the radio (the permission prompt may be on screen).
        for _ in 0..<120 where radio == .unknown { try? await Task.sleep(for: .milliseconds(250)) }
        report.append("radio: \(radio)")
        guard radio == .poweredOn else { return finish() }

        beginScanning()
        try? await Task.sleep(for: .seconds(25))
        endScanning()

        report.append("")
        report.append("Seen while scanning (\(discovered.count)):")
        for device in discovered.sorted(by: { $0.rssi > $1.rssi }) {
            report.append("  \(device.name)  rssi=\(device.rssi)  advertisesFlukeService=\(device.advertisesService)  likely=\(device.isLikely)  id=\(device.id.uuidString)")
        }

        let candidates = discovered.filter(\.isLikely).sorted {
            ($0.advertisesService ? 1 : 0, $0.rssi) > ($1.advertisesService ? 1 : 0, $1.rssi)
        }
        guard let device = candidates.first else {
            report.append("")
            report.append("No device that looks like a Fluke Connect device was seen. Is Bluetooth on at the meter, and is the Fluke Connect phone app closed?")
            return finish()
        }

        report.append("")
        report.append("Connecting to: \(device.name)")
        let meter: FlukeMeter
        if let saved = self.meter(id: device.id) {
            meter = saved
        } else {
            meter = FlukeMeter(id: device.id, name: device.name, connectionID: 1, central: central)
            adopt(meter)
        }
        connect(meter)
        // Keep scanning while connected, and note every Fluke-looking identifier and when it was seen:
        // if the meter ever shows up under a second identifier, this shows when.
        let listenStart = Date()
        var seen: [UUID: (name: String, first: TimeInterval, last: TimeInterval)] = [:]
        beginScanning()
        for second in 1...75 {
            try? await Task.sleep(for: .seconds(1))
            let offset = Date().timeIntervalSince(listenStart)
            for device in discovered where device.isLikely {
                seen[device.id] = (device.name, seen[device.id]?.first ?? offset, offset)
            }
            // Save what there is so far, so a run that gets cut short still leaves data.
            if second % 15 == 0 {
                let partial = report + ["", "[partial report at \(second) s, still running]", "link: \(meter.link)",
                                        "readings so far: \(meter.readingCount); session restarts: \(meter.linkResets)", "", "Log:", meter.logText]
                try? partial.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
        }
        endScanning()

        report.append("link: \(meter.link)  (session restarts after system re-connects: \(meter.linkResets))")
        report.append("Fluke-looking identifiers seen while connected (seconds into the listen):")
        for (id, entry) in seen.sorted(by: { $0.value.first < $1.value.first }) {
            report.append(String(format: "  %@  id=%@  first %.0f s  last %.0f s", entry.name, id.uuidString, entry.first, entry.last))
        }
        if seen.isEmpty { report.append("  (none)") }
        report.append("link: \(meter.link)")
        report.append("readings received: \(meter.readingCount); last one \(meter.lastReadingAt.map { String(format: "%.1f s ago", Date().timeIntervalSince($0)) } ?? "never")")
        report.append("info: \(meter.info)")
        if let reading = meter.reading {
            report.append("last reading: \(reading.functionName) \(reading.displayText) \(reading.unitSymbol)  state=\(reading.state)  attribute=\(reading.attribute ?? "none")")
        } else {
            report.append("last reading: none")
        }
        if let secondary = meter.secondary { report.append("secondary: \(secondary.functionName) \(secondary.displayText) \(secondary.unitSymbol)") }
        report.append("")
        report.append("Log:")
        report.append(meter.logText)
        meter.stop()
        finish()
    }
}
