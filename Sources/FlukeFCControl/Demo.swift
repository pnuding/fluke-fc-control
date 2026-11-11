import AppKit
import FlukeCore
import Foundation
import SwiftUI

// Dev-only simulation, no Bluetooth needed:
//   --demo                       two simulated meters (ID# 1 and 2), each in its own window
//   --demo --scenario <n>        start on scenario n and stay there
//   --demo --render <dir>        render the main views to PNGs (ImageRenderer), then quit
extension FlukeHub {
    /// Two simulated 1587FCs with their own ID#s, each opening in its own window. Called from `init`.
    func makeDemoMeters() {
        isDemo = true
        for number in 1...2 {
            let meter = FlukeMeter(id: UUID(), name: "FLUKE 1587FC", connectionID: UInt8(number), central: central)
            meter.isDemo = true
            meter.enabled = true
            meter.info.serial = number == 1 ? "1567380832" : "1567380911"
            meter.info.software = "V02.06.00"
            adopt(meter)
        }
        launchQueue = meters.map(\.id)
    }

    func startDemo() {
        radio = .poweredOn
        let args = ProcessInfo.processInfo.arguments
        let fixed = args.firstIndex(of: "--scenario").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }

        // The first meter shows an insulation test, the second a DC voltage, unless a scenario is forced.
        for (index, meter) in meters.enumerated() {
            meter.startDemo(scenario: fixed ?? (index == 0 ? 2 : 0))
        }

        let now = Date()
        discovered = [
            DiscoveredMeter(id: UUID(), name: "IR 3000 FC", rssi: -58, advertisesService: true, lastSeen: now),
            DiscoveredMeter(id: UUID(), name: "376FC", rssi: -71, advertisesService: false, lastSeen: now),
            DiscoveredMeter(id: UUID(), name: "Living Room Speaker", rssi: -80, advertisesService: false, lastSeen: now),
        ]
        scheduleRenderIfRequested()
        scheduleWindowCheckIfRequested()
    }
}

struct DemoScenario {
    let title: String
    let primary: (Int) -> Reading
    let secondary: Reading?
}

extension FlukeMeter {
    static let demoScenarios: [DemoScenario] = [
        DemoScenario(title: "DC voltage", primary: { tick in
            Reading(counts: UInt32(50_600 + (tick * 7) % 90), decimals: 4, unitCode: 2, functionCode: 12)
        }, secondary: nil),
        DemoScenario(title: "Resistance", primary: { tick in
            Reading(counts: UInt32(4_690 + (tick * 3) % 20), decimals: 3, magnitude: .kilo, unitCode: 11, functionCode: 40)
        }, secondary: nil),
        DemoScenario(title: "Insulation 500 V", primary: { tick in
            Reading(counts: UInt32(1_243 + (tick * 5) % 40), decimals: 1, magnitude: .mega, unitCode: 11, functionCode: 55)
        }, secondary: Reading(counts: 504, decimals: 0, unitCode: 2, functionCode: 52)),
        DemoScenario(title: "Continuity short", primary: { tick in
            Reading(counts: UInt32(42 + tick % 3), decimals: 2, unitCode: 11, functionCode: 39, attributeCode: 2)
        }, secondary: nil),
        DemoScenario(title: "AC voltage with hazard", primary: { tick in
            Reading(counts: UInt32(4_121 + (tick * 2) % 12), decimals: 1, unitCode: 1, functionCode: 2, attributeCode: 8)
        }, secondary: Reading(counts: 500, decimals: 1, unitCode: 5, functionCode: 23)),
        DemoScenario(title: "Capacitance overload", primary: { _ in
            Reading(counts: Reading.noValueCounts, state: .overRange, unitCode: 15, functionCode: 45)
        }, secondary: nil),
        DemoScenario(title: "Temperature", primary: { tick in
            Reading(counts: UInt32(224 + (tick / 8) % 3), decimals: 1, unitCode: 7, functionCode: 34)
        }, secondary: nil),
        DemoScenario(title: "Negative millivolts", primary: { tick in
            Reading(counts: UInt32(52 + tick % 4), decimals: 3, magnitude: .milli, isNegative: true, unitCode: 2, functionCode: 11)
        }, secondary: nil),
    ]

    /// Starts the simulated meter. With a fixed scenario it stays there; otherwise it cycles every 10 s.
    func startDemo(scenario fixed: Int?) {
        isDemo = true
        link = .connected
        info.model = "FLUKE 1587FC"
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let index = fixed ?? (tick / 40) % Self.demoScenarios.count
                let scenario = Self.demoScenarios[index % Self.demoScenarios.count]
                apply(scenario.primary(tick), scenario.secondary)
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: - Off-screen rendering

extension FlukeHub {
    /// ImageRenderer needs no Screen Recording permission. Platform-backed pieces (ScrollView, Button,
    /// Chart) and the glass material may not draw off-screen, so this is a layout/content check.
    func scheduleRenderIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--render"), i + 1 < args.count else { return }
        let dir = args[i + 1]
        Task {
            try? await Task.sleep(for: .seconds(1))
            renderImages(to: dir)
            NSApp.terminate(nil)
        }
    }

    private func renderImages(to dir: String) {
        guard let meter = meters.first else { return }
        meter.demoTask?.cancel()

        func render<V: View>(_ view: V, name: String, dark: Bool = false, width: CGFloat? = nil) {
            var framed = AnyView(view
                .environment(self)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.glassEnabled, false))
            if let width { framed = AnyView(framed.frame(width: width).fixedSize(horizontal: false, vertical: true)) }
            let backed = framed.background(dark ? Color(white: 0.12) : Color(white: 0.97))
            let renderer = ImageRenderer(content: backed)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("render failed: \(name)")
                return
            }
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("rendered \(name)")
        }

        func main() -> some View { MeasurementCardView(meter: meter).padding(16).fixedSize() }

        for (index, scenario) in FlukeMeter.demoScenarios.enumerated() {
            meter.apply(scenario.primary(3), scenario.secondary)
            meter.lastReadingAt = Date()
            render(main(), name: "main_\(index)")
            if index == 2 || index == 4 { render(main(), name: "main_\(index)_dark", dark: true) }
        }

        // Worst case for the card header (it never wraps): the longest function name next to the widest badge.
        meter.apply(Reading(counts: Reading.noValueCounts, state: .blank, magnitude: .mega, unitCode: 11, functionCode: 73, attributeCode: 8),
                    Reading(counts: 500, unitCode: 2, functionCode: 52))
        render(main(), name: "main_long")

        // Link states other than "streaming".
        meter.apply(FlukeMeter.demoScenarios[0].primary(3), nil)
        meter.lastReadingAt = Date().addingTimeInterval(-30)
        render(main(), name: "state_stale")
        meter.link = .connecting
        render(main(), name: "state_connecting")
        meter.link = .retrying("The meter didn't answer in time.")
        render(main(), name: "state_retrying")
        meter.link = .bluetoothUnavailable("Bluetooth is turned off.")
        render(main(), name: "state_bluetooth_off")
        meter.link = .connected
        meter.lastReadingAt = nil
        render(main(), name: "state_waiting")
        meter.lastReadingAt = Date()

        render(ConnectionView(open: { _ in }), name: "connection", width: 480)
        showOtherDevices = true
        render(ConnectionView(open: { _ in }), name: "connection_others", width: 480)
        // A crowded room: the dialog must stay a sane height however many devices there are.
        let saved = discovered
        discovered += (1...40).map { DiscoveredMeter(id: UUID(), name: "Device \($0)", rssi: -60 - $0, advertisesService: false, lastSeen: Date()) }
        render(ConnectionView(open: { _ in }), name: "connection_many", width: 480)
        discovered = saved
        showOtherDevices = false

        // Graph with a synthetic recording that has an over-range gap.
        let series = GraphSeries(unitCode: 2, label: "V DC", symbol: "V")
        for n in 0..<240 {
            let t = Double(n) * 0.25
            let overload = (110..<122).contains(n)
            series.add(GraphPoint(t: t, y: 5 + 0.8 * sin(t / 4) + 0.02 * sin(t * 7), isOverload: overload))
        }
        meter.recorder.series = series
        render(GraphView(meter: meter).frame(width: 560, height: 420).padding(), name: "graph")
        meter.recorder.series = nil
        meter.recorder.notice = "Recording stopped: the meter switched to a different measurement."
        render(GraphView(meter: meter).frame(width: 560, height: 200).padding(), name: "graph_empty")
        meter.recorder.notice = nil

        meter.note("connect() → 6B2F0D3A-0000-0000-0000-000000000000 state=0")
        meter.note("services: 1800, 180A, B6981800-7562-11E2-B50D-00163E46F8FE")
        meter.note("  B698290F-7562-11E2-B50D-00163E46F8FE  [read,notify]")
        meter.note("← 290F [8] d9 c5 00 08 02 0c 00 00  →  DC Voltage: 5.0649 V")
        render(DiagnosticsView(meter: meter).frame(width: 560, height: 220).padding(), name: "diagnostics")
    }
}

// MARK: - Window check (verifies the multi-window and tabbing behaviour in the real app)

extension FlukeHub {
    /// `FLUKE_CHECK_WINDOWS=<path>` with `--demo`: after the windows have settled, writes each window's title and tab
    /// state, merges them into tabs, writes that too, and quits.
    func scheduleWindowCheckIfRequested() {
        // The path comes from the environment, not an argument: AppKit treats a path on the command line as a
        // file to open, and an app launched that way doesn't open its normal windows.
        guard let path = ProcessInfo.processInfo.environment["FLUKE_CHECK_WINDOWS"] else { return }
        Task {
            var timeline: [String] = []
            for step in 0..<12 {
                try? await Task.sleep(for: .milliseconds(500))
                timeline.append("t=\(Double(step + 1) * 0.5)s windows=\(NSApp.windows.count) ordered=\(NSApp.orderedWindows.count) keyWindow=\(NSApp.keyWindow != nil)")
            }
            let windowsBeforeActivating = NSApp.windows.count
            NSApp.activate()
            try? await Task.sleep(for: .seconds(3))
            @MainActor func windowLines() -> [String] {
                NSApp.windows.map { window in
                    "\(type(of: window)) main=\(window.canBecomeMain) title=\"\(window.title)\" visible=\(window.isVisible) tabs=\(window.tabGroup?.windows.count ?? 1) tabbingMode=\(window.tabbingMode.rawValue)"
                }
            }
            var report = timeline
            report += ["windows before activating: \(windowsBeforeActivating)"]
            report += ["activationPolicy=\(NSApp.activationPolicy().rawValue) active=\(NSApp.isActive) windows=\(NSApp.windows.count) delegate=\(String(describing: NSApp.delegate.map { type(of: $0) }))"]
            report += ["Windows after launch:"] + windowLines().map { "  " + $0 }
            report.append("meters: " + meters.map { "\($0.title) [\($0.link)]" }.joined(separator: " | "))

            NSApp.windows.first(where: { $0.canBecomeMain })?.mergeAllWindows(nil)
            try? await Task.sleep(for: .seconds(1.5))
            report.append("After Merge All Windows:")
            report += windowLines().map { "  " + $0 }
            if let group = NSApp.windows.first(where: { $0.canBecomeMain })?.tabGroup {
                report.append("tab group: \(group.windows.count) windows, selected=\"\(group.selectedWindow?.title ?? "-")\"")
                // Switching tabs must not disconnect anything.
                if let other = group.windows.first(where: { $0 !== group.selectedWindow }) { group.selectedWindow = other }
                try? await Task.sleep(for: .seconds(1))
                report.append("after switching tab: " + meters.map { "\($0.title) enabled=\($0.enabled)" }.joined(separator: " | "))
            }
            @MainActor func state() -> String { meters.map { "ID# \($0.connectionID) enabled=\($0.enabled) link=\($0.link)" }.joined(separator: " | ") }

            // File → New Window: an extra window with no meter of its own (the meter picker).
            _ = NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            try? await Task.sleep(for: .seconds(1.5))
            report.append("After File → New Window:")
            report += windowLines().map { "  " + $0 }
            let picker = NSApp.windows.first { $0.canBecomeMain && !$0.title.contains("ID#") }
            report.append("meters unchanged by it: " + state())

            // Closing one meter's window disconnects that meter only.
            picker?.close()
            try? await Task.sleep(for: .seconds(0.5))
            let windowsByTitle = NSApp.windows.filter { $0.canBecomeMain }
            if let second = windowsByTitle.first(where: { $0.title.contains("ID# 2") }) {
                second.close()
                try? await Task.sleep(for: .seconds(0.5))
                report.append("after closing the ID# 2 window: " + state())
            }
            // Closing the last window quits the app, and the meter must stay set to reconnect next launch.
            if let first = NSApp.windows.first(where: { $0.canBecomeMain && $0.title.contains("ID# 1") }) {
                first.close()
                report.append("after closing the last window: " + state())
            }
            try? report.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
