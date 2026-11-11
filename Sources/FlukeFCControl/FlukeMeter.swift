import FlukeCore
import Foundation
import Observation

/// One meter (or adapter): its connection, its latest reading, its graph recording and a diagnostics log.
/// The hub owns every saved meter and the shared Bluetooth central; any number of meters can be connected
/// at once, each in its own window.
///
/// The Fluke Connect protocol as far as anyone has published it is read-only for these devices:
/// subscribe to the reading characteristic and the meter streams what its display shows. Function
/// and range are chosen on the meter itself. The one thing this app writes is its connection ID.
@MainActor
@Observable
final class FlukeMeter: Identifiable {
    enum Link: Equatable {
        /// Not connected (switched off).
        case idle
        case bluetoothUnavailable(String)
        case connecting
        case connected
        case retrying(String)
    }

    let id: UUID
    /// Name from the advertisement; replaced by the model the device reports once connected.
    var name: String
    /// The ID# written to this meter and shown on its display (unique among saved meters, stable across launches).
    let connectionID: UInt8
    /// The user wants this meter connected (and open in a window) at launch.
    var enabled = false
    let recorder = GraphRecorder()

    /// Window title: the name, then the ID#.
    var title: String { "\(name) · ID# \(connectionID)" }
    /// Firmware as shown next to the serial number in the meter list.
    var firmwareText: String? { info.software ?? info.firmware }

    var link: Link = .idle
    var info = DeviceInfo()

    // MARK: Live data

    var reading: Reading?
    var secondary: Reading?
    /// Read by a view that ticks once a second, so it needn't be observed itself.
    @ObservationIgnored var lastReadingAt: Date?

    // MARK: Diagnostics

    /// Newest last. Only the Diagnostics window reads this, so appending doesn't redraw the main window.
    private(set) var log: [String] = []

    // MARK: Internals

    @ObservationIgnored let transport: BLETransport
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lastBinaryAt: Date?
    @ObservationIgnored private var hasBinaryReading = false
    @ObservationIgnored private var linkWasReestablished = false
    /// Last value seen on each watched characteristic, so only changes are logged.
    @ObservationIgnored private var lastWatched: [String: [UInt8]] = [:]
    @ObservationIgnored private var watchingExtras = false
    /// How many times the session had to be rebuilt after the system re-connected underneath it.
    @ObservationIgnored private(set) var linkResets = 0
    @ObservationIgnored private var lastLoggedPayload: [UInt8]?
    @ObservationIgnored private var suppressedPayloads = 0
    @ObservationIgnored private var lastSteadyNote = Date()
    /// How many readings arrived on this connection (probe report and diagnostics).
    @ObservationIgnored private(set) var readingCount = 0
    @ObservationIgnored var isDemo = false
    @ObservationIgnored var demoTask: Task<Void, Never>?
    /// The device told us its name, serial number or firmware; the hub persists them.
    @ObservationIgnored var onInfoChange: (@MainActor () -> Void)?

    private static let maxLogLines = 500
    private static let quietBeforePolling: TimeInterval = 4
    private static let quietBeforeReconnect: TimeInterval = 15

    init(id: UUID, name: String, connectionID: UInt8, central: BLECentral) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.transport = BLETransport(central: central, id: id)
        transport.onEvent = { [weak self] text in self?.note(text) }
        transport.onLinkReestablished = { [weak self] in self?.linkWasReestablished = true }
        transport.onBinaryReading = { [weak self] data in self?.receiveBinary(data) }
        transport.onAsciiReading = { [weak self] data in self?.receiveASCII(data) }
        transport.onValue = { [weak self] uuid, data in self?.receiveInfo(uuid, data) }
    }

    // MARK: Lifecycle

    func start(radio: RadioState) {
        isActive = true
        radioChanged(radio)
    }

    func stop() {
        isActive = false
        shutdown()
        link = .idle
    }

    func radioChanged(_ state: RadioState) {
        guard isActive, !isDemo else { return }
        switch state {
        case .poweredOn:
            if connectionTask == nil { beginConnecting() }
        case .poweredOff:
            stopConnecting(.bluetoothUnavailable(String(localized: "Bluetooth is turned off.")))
        case .unauthorized:
            stopConnecting(.bluetoothUnavailable(String(localized: "Bluetooth access is denied. Allow it for this app in System Settings → Privacy & Security → Bluetooth.")))
        case .unsupported:
            stopConnecting(.bluetoothUnavailable(String(localized: "This Mac doesn't support Bluetooth Low Energy.")))
        case .unknown:
            link = .connecting
        }
    }

    func shutdown() {
        connectionTask?.cancel()
        connectionTask = nil
        demoTask?.cancel()
        demoTask = nil
        transport.disconnect()
    }

    func reconnect(radio: RadioState) {
        shutdown()
        start(radio: radio)
    }

    private func stopConnecting(_ link: Link) {
        shutdown()
        self.link = link
    }

    // MARK: Connection loop

    private func beginConnecting() {
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in await self?.runConnectionLoop() }
    }

    /// Connects, streams until the link drops, then reconnects. Meters switch Bluetooth off when they
    /// power down and some drop the link on a timer, so reconnecting is the normal path.
    private func runConnectionLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            // After a failure the "retrying: <reason>" state stays up until we're connected again.
            if attempt == 0 { link = .connecting }
            var keepLink = false
            do {
                try await connectAndStream(attempt: &attempt)
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                // The system re-connected under us: the new link is fine, only our session on it is gone.
                // Keep it and rebuild the session instead of cancelling (which the meter reacts badly to).
                if case MeterError.linkReestablished = error { keepLink = true; attempt = 0 }
                link = .retrying(error.localizedDescription)
                note("link ended: \(error.localizedDescription)")
            }
            if !keepLink { transport.disconnect() }
            guard !Task.isCancelled else { break }
            attempt += 1
            try? await Task.sleep(for: .seconds(keepLink ? 0.3 : min(Double(attempt) * 2, 10)))
        }
    }

    private func connectAndStream(attempt: inout Int) async throws {
        try await transport.connect()

        guard transport.hasService(FlukeUUID.readingService) else { throw MeterError.notAFlukeDevice }
        linkWasReestablished = false
        let hasBinary = transport.has(FlukeUUID.binaryReading)
        hasBinaryReading = hasBinary
        let hasASCII = transport.has(FlukeUUID.asciiReading)
        guard hasBinary || hasASCII else { throw MeterError.noReadingCharacteristic }

        // Identify this client: the meter shows the number as "ID#" on its display, as it does for Fluke's
        // own app, and seems to drop connections that never do. A failure here isn't fatal.
        if transport.has(FlukeUUID.connectionID) {
            do { try await transport.writeConnectionID(connectionID) } catch {
                note("couldn't set the connection ID: \(error.localizedDescription)")
            }
        }
        if hasBinary { try await transport.setNotify(true, uuid: FlukeUUID.binaryReading) }
        if hasASCII { try? await transport.setNotify(true, uuid: FlukeUUID.asciiReading) }
        lastWatched = [:]
        watchingExtras = UserDefaults.standard.bool(forKey: Pref.watchExtras)
        if watchingExtras { note("watching the undocumented state characteristics (Diagnostics toggle)") }
        for uuid in FlukeUUID.watchedNotify where watchingExtras && transport.has(uuid) {
            do { try await transport.setNotify(true, uuid: uuid) } catch { note("couldn't watch \(uuid.prefix(8)): \(error.localizedDescription)") }
        }

        link = .connected
        attempt = 0
        readDeviceInfo()

        // Watch the stream. Notifications normally arrive several times a second (also in HOLD: the meter
        // repeats the displayed value), but the 1587 FC's stream has been seen to stop on a link
        // CoreBluetooth still reports as connected. So when it goes quiet, ask for the current value
        // directly: an answer proves the link is alive (and shows what the display shows); no answer
        // means it isn't.
        let connectedAt = Date()
        var ticks = 0
        var lastQuietNote = Date.distantPast
        while !Task.isCancelled, transport.isConnected {
            try await Task.sleep(for: .seconds(1))
            if linkWasReestablished {
                linkWasReestablished = false
                linkResets += 1
                throw MeterError.linkReestablished
            }
            ticks += 1
            if watchingExtras, ticks % 2 == 0 {
                for uuid in FlukeUUID.watchedPolled where transport.has(uuid) { transport.read(uuid) }
            }

            let quiet = Date().timeIntervalSince(max(lastReadingAt ?? connectedAt, connectedAt))
            guard quiet >= Self.quietBeforePolling else { continue }
            if Date().timeIntervalSince(lastQuietNote) > 30 {
                lastQuietNote = Date()
                note("no readings for \(Int(quiet)) s (\(transport.stateSummary)); polling by read")
            }
            if hasBinaryReading { transport.read(FlukeUUID.binaryReading) }
            if quiet >= Self.quietBeforeReconnect {
                note("no answer for \(Int(quiet)) s; reconnecting")
                throw MeterError.timeout
            }
        }
        if !Task.isCancelled { throw MeterError.notConnected }
    }

    /// Reads the standard info (model, serial, firmware) and, for the diagnostics log, every
    /// other readable characteristic once. Reads only: the firmware-update characteristics are skipped
    /// and the live-reading ones already notify.
    private func readDeviceInfo() {
        readingCount = 0
        let skipped = FlukeUUID.firmwareUpdateWarning.union([FlukeUUID.binaryReading, FlukeUUID.asciiReading])
        for uuid in transport.readableUUIDs where !skipped.contains(uuid) { transport.read(uuid) }
    }

    // MARK: Incoming data

    private func receiveBinary(_ data: Data) {
        lastBinaryAt = Date()
        let bytes = [UInt8](data)
        guard let packet = ReadingPacket(payload: bytes) else {
            logPayload("←", "290F", bytes, decoded: "ignored (shorter than 8 bytes)")
            return
        }
        var decoded = "\(packet.primary.functionName): \(packet.primary.displayText) \(packet.primary.unitSymbol)"
        if let attribute = packet.primary.attribute { decoded += " [\(attribute)]" }
        let p = packet.primary
        decoded += "  {range \(p.range) decade \(p.decade) attr \(p.attributeCode) capture \(p.capture ? 1 : 0)}"
        if let secondary = packet.secondary { decoded += "  |  2nd \(secondary.functionName): \(secondary.displayText) \(secondary.unitSymbol)" }
        logPayload("←", "290F", bytes, decoded: decoded)
        apply(packet.primary, packet.secondary)
    }

    private func receiveASCII(_ data: Data) {
        let bytes = [UInt8](data)
        let parsed = AsciiReading.parse(bytes)
        logPayload("←", "2901", bytes, decoded: parsed.map { "\($0.displayText) \($0.unitSymbol)" } ?? "unparsed")
        // Binary wins whenever the device sends it.
        if let lastBinaryAt, Date().timeIntervalSince(lastBinaryAt) < 5 { return }
        if let parsed { apply(parsed, nil) }
    }

    private func receiveInfo(_ uuid: String, _ data: Data) {
        let bytes = [UInt8](data)
        if FlukeUUID.watched.contains(uuid) {
            guard lastWatched[uuid] != bytes else { return }
            let previous = lastWatched[uuid]
            lastWatched[uuid] = bytes
            let printable = bytes.filter { $0 != 0 }
            let text = !printable.isEmpty && printable.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                ? "  \"" + String(decoding: printable, as: UTF8.self) + "\"" : ""
            note("watch \(uuid.prefix(8)) [\(bytes.count)] \(bytes.hexString)\(text)" + (previous == nil ? "  (first)" : "  (was \(previous!.hexString))"))
            return
        }
        let printable = bytes.filter { $0 != 0 }
        let text = !printable.isEmpty && printable.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            ? "  \"" + String(decoding: printable, as: UTF8.self) + "\"" : ""
        note("read \(uuid): \(bytes.count) bytes \(bytes.hexString)\(text)")
        let before = (info.model ?? info.name, info.serial, firmwareText)
        guard info.absorb(uuid: uuid, value: data) else { return }
        // Replace the generic scan name with what the device calls itself.
        if let new = info.model ?? info.name, name != new { name = new }
        if (info.model ?? info.name, info.serial, firmwareText) != before { onInfoChange?() }
    }

    func apply(_ primary: Reading, _ secondary: Reading?) {
        readingCount += 1
        reading = primary
        self.secondary = secondary
        lastReadingAt = Date()
        recorder.ingest(primary)
    }

    // MARK: Diagnostics

    func note(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        log.append("\(stamp)  \(text)")
        // The file is shared by every meter, so its lines say which one they belong to.
        if !isDemo { DiagnosticsFile.append("\(stamp)  [ID# \(connectionID)] \(text)") }
        if log.count > Self.maxLogLines { log.removeFirst(log.count - Self.maxLogLines) }
    }

    /// Readings arrive several times a second; identical consecutive payloads are counted rather than
    /// logged line by line, so a steady value is distinguishable from no data at all.
    private func logPayload(_ direction: String, _ channel: String, _ bytes: [UInt8], decoded: String) {
        let now = Date()
        guard bytes != lastLoggedPayload else {
            suppressedPayloads += 1
            if now.timeIntervalSince(lastSteadyNote) >= 10 {
                lastSteadyNote = now
                note("   … \(suppressedPayloads) identical readings so far (value is steady)")
            }
            return
        }
        if suppressedPayloads > 0 {
            note("   … +\(suppressedPayloads) identical readings")
            suppressedPayloads = 0
        }
        lastLoggedPayload = bytes
        lastSteadyNote = now
        note("\(direction) \(channel) [\(bytes.count)] \(bytes.hexString)  →  \(decoded)")
    }

    func clearLog() { log.removeAll() }

    var logText: String { log.joined(separator: "\n") }
}
