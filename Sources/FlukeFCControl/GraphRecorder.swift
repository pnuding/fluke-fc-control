import AppKit
import FlukeCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Not Identifiable-via-UUID: within one series `t` is strictly increasing, so views use
// ForEach(id: \.t) instead of allocating a UUID per sample.
struct GraphPoint {
    let t: Double
    /// In the unit's base (V, A, Ω…); meaningless when `isOverload`.
    let y: Double
    /// An over-range ("OL") sample: drawn as a gap, exported as "OL".
    let isOverload: Bool
}

final class GraphSeries {
    let unitCode: UInt8
    /// "V DC": the unit with its qualifier.
    let label: String
    /// "V": the bare unit, for formatting values.
    let symbol: String
    var points: [GraphPoint] = []

    // Running statistics over the real (non-overload) samples, so showing them never rescans a long recording.
    private(set) var count = 0
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity
    private var sum = 0.0

    init(unitCode: UInt8, label: String, symbol: String) {
        self.unitCode = unitCode
        self.label = label
        self.symbol = symbol
    }

    var mean: Double? { count > 0 ? sum / Double(count) : nil }
    var hasStatistics: Bool { count > 0 }

    func add(_ point: GraphPoint) {
        points.append(point)
        guard !point.isOverload else { return }
        count += 1
        sum += point.y
        minimum = Swift.min(minimum, point.y)
        maximum = Swift.max(maximum, point.y)
    }
}

/// Records the live reading into a chart-able series and exports it. Lives at app level, so a
/// recording survives switching or disconnecting meters (but stops if the measurement changes).
@MainActor
@Observable
final class GraphRecorder {
    var graphing = false
    var series: GraphSeries?
    /// Why a recording stopped by itself, until the next Start.
    var notice: String?

    @ObservationIgnored private var startTime = Date()
    @ObservationIgnored private var lastPublish = Date.distantPast

    /// Feeds one reading from the meter. Blank/invalid readings carry no information and are skipped.
    func ingest(_ reading: Reading) {
        guard graphing else { return }
        guard reading.state.hasNumber || reading.state.isOverload else { return }
        if let series, series.unitCode != reading.unitCode {
            // A different unit would mix two measurements under one label (e.g. V DC then Ω).
            graphing = false
            notice = String(localized: "Recording stopped: the meter switched to a different measurement.")
            publish()
            return
        }
        let current = series ?? GraphSeries(unitCode: reading.unitCode, label: reading.unit.label, symbol: reading.unit.symbol)
        if series == nil { series = current }
        let t = Date().timeIntervalSince(startTime)
        current.add(GraphPoint(t: t, y: reading.value ?? 0, isOverload: reading.state.isOverload || reading.value == nil))
        // Publishing per sample would invalidate the chart on every notification (~4 per second).
        // The data is recorded at full rate; only the UI notification is coalesced to ~1 Hz.
        let now = Date()
        if now.timeIntervalSince(lastPublish) >= 1.0 {
            lastPublish = now
            publish()
        }
    }

    /// A no-op mutation on `series` is how in-place appends become visible to @Observable tracking.
    private func publish() {
        withMutation(keyPath: \.series) {}
    }

    func start() {
        series = nil
        notice = nil
        startTime = Date()
        lastPublish = .distantPast
        graphing = true
    }

    func stop() { graphing = false }

    func clear() {
        series = nil
        notice = nil
    }

    /// Writes every recorded sample (not the chart's decimated subset) as CSV.
    func exportCSV() {
        guard let series, !series.points.isEmpty else { return }
        var rows = [["time_s", "value", "unit"]]
        for p in series.points {
            rows.append([
                String(format: "%.3f", p.t),
                p.isOverload ? "OL" : String(format: "%.9g", p.y),
                series.label,
            ])
        }
        let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "fluke-log-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        // begin(), not runModal(): the modal variant parks the main run loop while the dialog is open,
        // which would stall the live readings (and any recording) while you browse for a folder.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Could not save CSV")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
