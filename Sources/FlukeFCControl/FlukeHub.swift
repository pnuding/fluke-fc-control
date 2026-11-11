import AppKit
import CoreBluetooth
import FlukeCore
import Foundation
import Observation
import SwiftUI

/// App-level state: the shared Bluetooth central, every meter this Mac knows (any number of them can be
/// connected at once, each in its own window), and what's in range.
@MainActor
@Observable
final class FlukeHub {
    let central = BLECentral()

    private(set) var meters: [FlukeMeter] = []
    var radio: RadioState = .unknown
    /// Everything advertising nearby that could be listed (meters already added included; use the `nearby…` lists for the picker).
    var discovered: [DiscoveredMeter] = []
    /// The picker's "other Bluetooth devices" disclosure, for a meter that doesn't advertise the Fluke service.
    var showOtherDevices = false
    /// Meters that got added without anyone clicking Add (first run, exactly one Fluke device in range). An
    /// empty "choose a meter" window turns itself into the first of them.
    var autoOpenRequests: [UUID] = []

    @ObservationIgnored var isDemo = false
    /// Set by `--probe`: nothing is saved.
    @ObservationIgnored var isProbe = false
    /// Set when the app starts terminating, so windows closing on the way out don't count as "disconnect this meter".
    @ObservationIgnored var isQuitting = false
    /// Meters whose window should open at launch. The first window SwiftUI creates takes the first one and
    /// opens the others (see `MeterWindow`); filled in `init` so it is ready before any window appears.
    @ObservationIgnored var launchQueue: [UUID] = []
    /// Meters someone asked a window for; each new window takes the first one (see `MeterWindow`).
    @ObservationIgnored private var pendingWindows: [UUID] = []
    private struct WeakWindow { weak var window: NSWindow? }
    /// The window currently showing each meter.
    @ObservationIgnored private var windows: [UUID: WeakWindow] = [:]
    @ObservationIgnored private var scanUsers = 0
    @ObservationIgnored private var autoAddTask: Task<Void, Never>?

    init() {
        // Dev-only simulation: two simulated meters, set up here because the first window asks for them at once.
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            makeDemoMeters()
            return
        }
        let defaults = UserDefaults.standard
        let legacyActive = defaults.string(forKey: Pref.activeMeter).flatMap(UUID.init)
        var used = Set<Int>()
        var saved = Self.loadSaved()
        // Older saved lists have no ID# or "connect at launch" flag: give every meter its own number, and keep
        // the meter that was active before connecting at launch.
        for entry in saved { if let number = entry.connectionID { used.insert(number) } }
        for index in saved.indices where saved[index].connectionID == nil {
            let number = ConnectionID.next(avoiding: used) ?? 1
            saved[index].connectionID = number
            used.insert(number)
        }
        for entry in saved {
            let meter = FlukeMeter(id: entry.id, name: entry.name, connectionID: UInt8(clamping: entry.connectionID ?? 1), central: central)
            meter.enabled = entry.enabled ?? (entry.id == legacyActive)
            meter.info.serial = entry.serial
            meter.info.software = entry.firmware
            adopt(meter)
        }
        launchQueue = meters.filter(\.enabled).map(\.id)
        if !saved.isEmpty { persist() }
    }

    // MARK: Lifecycle

    func start() {
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            startDemo()
            return
        }
        central.onRadioChange = { [weak self] state in self?.radioChanged(state) }
        central.onDiscover = { [weak self] device in self?.deviceDiscovered(device) }
        // Written to the log file so "nothing happens at launch" can be told apart from "waiting for the
        // Bluetooth permission": authorization 0 = not asked yet, 1 = restricted, 2 = denied, 3 = allowed.
        logGlobal("launch: Bluetooth authorization=\(CBManager.authorization.rawValue), \(meters.filter(\.enabled).count) meter(s) set to connect")
        central.start()
        startProbeIfRequested()
        if !isProbe {
            for meter in meters where meter.enabled { meter.start(radio: radio) }
        }
        updateScanning()
    }

    func shutdown() {
        meters.forEach { $0.shutdown() }
    }

    private func logGlobal(_ text: String) {
        guard !isDemo, !isProbe else { return }
        DiagnosticsFile.append("\(Date().formatted(.dateTime.hour().minute().second()))  [app] \(text)")
    }

    private func radioChanged(_ state: RadioState) {
        logGlobal("Bluetooth radio: \(state)")
        radio = state
        meters.forEach { $0.radioChanged(state) }
        updateScanning()
    }

    // MARK: Meters

    func meter(id: UUID) -> FlukeMeter? { meters.first { $0.id == id } }

    /// Saves a discovered device with its own ID# and connects to it. The caller opens its window.
    @discardableResult
    func add(_ device: DiscoveredMeter) -> FlukeMeter {
        if let existing = meter(id: device.id) { return existing }
        let number = ConnectionID.next(avoiding: meters.map { Int($0.connectionID) }) ?? 1
        let meter = FlukeMeter(id: device.id, name: device.name, connectionID: UInt8(clamping: number), central: central)
        adopt(meter)
        connect(meter)
        return meter
    }

    func connect(_ meter: FlukeMeter) {
        meter.enabled = true
        persist()
        meter.start(radio: radio)
        updateScanning()
    }

    func disconnect(_ meter: FlukeMeter) {
        meter.enabled = false
        persist()
        meter.stop()
        updateScanning()
    }

    func reconnect(_ meter: FlukeMeter) {
        meter.enabled = true
        persist()
        meter.reconnect(radio: radio)
    }

    func forget(_ meter: FlukeMeter) {
        meter.stop()
        meters.removeAll { $0.id == meter.id }
        persist()
        updateScanning()
    }

    func adopt(_ meter: FlukeMeter) {
        meter.onInfoChange = { [weak self] in self?.persist() }
        meters.append(meter)
    }

    // MARK: Windows

    /// Hands the launch list to the first window that asks; later windows get nothing.
    func takeLaunchQueue() -> [UUID] {
        defer { launchQueue = [] }
        return launchQueue.filter { meter(id: $0) != nil }
    }

    /// A new, empty window takes the meter somebody asked a window for, if any.
    func takePendingWindow() -> UUID? {
        while !pendingWindows.isEmpty {
            let id = pendingWindows.removeFirst()
            if meter(id: id) != nil, !isWindowOpen(id) { return id }
        }
        return nil
    }

    func requestWindow(for id: UUID) { pendingWindows.append(id) }

    func isWindowOpen(_ id: UUID) -> Bool { windows[id]?.window != nil }

    /// Brings the meter's window to the front (also selecting its tab), or opens one for it.
    func showWindow(for meter: FlukeMeter, openWindow: OpenWindowAction) {
        if let window = windows[meter.id]?.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            requestWindow(for: meter.id)
            openWindow(id: "meter")
        }
    }

    func meterWindowOpened(_ id: UUID, window: NSWindow) { windows[id] = WeakWindow(window: window) }

    /// A meter's window really closed (not just another tab coming to the front). A meter accepts only one
    /// connection, so it shouldn't stay held by a window you can't see: closing disconnects it. Not when the
    /// app is quitting, or this was the last window (the app quits then): the meter should reconnect next launch.
    func meterWindowClosed(_ id: UUID, window: NSWindow) {
        if windows[id]?.window === window { windows[id] = nil }
        guard !isQuitting, let meter = meter(id: id) else { return }
        let otherWindowsExist = windows.values.contains { $0.window != nil }
            || NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain }
        if otherWindowsExist { disconnect(meter) }
    }

    // MARK: Discovery

    /// Likely Fluke devices that aren't saved yet.
    var nearbyLikely: [DiscoveredMeter] {
        discovered.filter { device in device.isLikely && meter(id: device.id) == nil }
    }

    /// Named devices that don't look like Fluke ones, for the "other devices" list.
    var nearbyOthers: [DiscoveredMeter] {
        discovered.filter { device in !device.isLikely && meter(id: device.id) == nil }
    }

    /// The picker calls these while it's open. With no meters saved we scan regardless.
    func beginScanning() { scanUsers += 1; updateScanning() }
    func endScanning() { scanUsers = max(scanUsers - 1, 0); updateScanning() }

    private func updateScanning() {
        guard !isDemo else { return }
        if radio == .poweredOn, scanUsers > 0 || meters.isEmpty {
            central.startScan()
        } else {
            central.stopScan()
        }
    }

    private func deviceDiscovered(_ device: DiscoveredMeter) {
        let now = Date()
        if let index = discovered.firstIndex(where: { $0.id == device.id }) {
            // Fluke devices advertise every ~10 s, others far more often; update a row at most once a second.
            let old = discovered[index]
            let changed = old.name != device.name || old.advertisesService != device.advertisesService
            guard changed || now.timeIntervalSince(old.lastSeen) >= 1 else { return }
            discovered[index] = device
        } else {
            discovered.append(device)
            discovered.sort { ($0.isLikely ? 0 : 1, $0.name) < ($1.isLikely ? 0 : 1, $1.name) }
        }
        // Devices quiet for a minute are gone.
        discovered.removeAll { now.timeIntervalSince($0.lastSeen) > 60 }
        autoAddIfUnambiguous()
    }

    /// First run, exactly one device in range that advertises the Fluke service: just add it.
    private func autoAddIfUnambiguous() {
        guard meters.isEmpty, autoAddTask == nil, !isProbe else { return }
        autoAddTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            autoAddTask = nil
            let candidates = nearbyLikely.filter(\.advertisesService)
            if meters.isEmpty, candidates.count == 1, let only = candidates.first {
                autoOpenRequests.append(add(only).id)
            }
        }
    }

    // MARK: Persistence

    private func persist() {
        guard !isDemo, !isProbe else { return }
        let saved = meters.map {
            SavedMeter(id: $0.id, name: $0.name, connectionID: Int($0.connectionID), enabled: $0.enabled,
                       serial: $0.info.serial, firmware: $0.firmwareText)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Pref.meters)
    }

    private static func loadSaved() -> [SavedMeter] {
        guard let data = UserDefaults.standard.data(forKey: Pref.meters),
              let saved = try? JSONDecoder().decode([SavedMeter].self, from: data) else { return [] }
        return saved
    }
}
