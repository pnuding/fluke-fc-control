import CoreBluetooth
import FlukeCore
import Foundation

struct DiscoveredMeter: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    /// The Fluke reading service was in the advertisement: the strongest sign this is a Fluke Connect device.
    var advertisesService: Bool
    var lastSeen: Date

    /// Fluke Connect devices advertise the reading service. Names are a weaker hint ("IR 3000 FC", "1587FC").
    var isLikely: Bool { advertisesService || Self.nameLooksLikeFluke(name) }

    static func nameLooksLikeFluke(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("fluke") || lower.hasSuffix("fc") || lower.contains(" fc")
    }
}

enum RadioState: Equatable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported
}

enum MeterError: LocalizedError {
    case timeout
    case notConnected
    case bluetoothUnavailable(String)
    case notAFlukeDevice
    case noReadingCharacteristic
    case linkReestablished

    var errorDescription: String? {
        switch self {
        case .timeout: String(localized: "The meter didn't answer in time.")
        case .notConnected: String(localized: "Not connected to the meter.")
        case .bluetoothUnavailable(let why): why
        case .notAFlukeDevice: String(localized: "This device doesn't offer the Fluke Connect reading service. See Diagnostics for what it does offer.")
        case .noReadingCharacteristic: String(localized: "The device is connected but has no live-reading characteristic. See Diagnostics for what it offers.")
        case .linkReestablished: String(localized: "The Bluetooth link was re-established by the system; restarting the session.")
        }
    }
}

/// The one CBCentralManager shared by every meter: radio state, scanning, and routing connection
/// events to the right per-meter link.
@MainActor
final class BLECentral: NSObject {
    private(set) var radio: RadioState = .unknown
    var onRadioChange: (@MainActor (RadioState) -> Void)?
    var onDiscover: (@MainActor (DiscoveredMeter) -> Void)?

    private struct WeakLink { weak var link: BLETransport? }

    // Created in `start()` rather than `init`, so the Bluetooth permission prompt appears when the
    // app is ready for it, not at an arbitrary point.
    private var manager: CBCentralManager?
    private var known: [UUID: CBPeripheral] = [:]
    private var links: [UUID: WeakLink] = [:]

    private static let serviceID = CBUUID(string: FlukeUUID.readingService)

    var isReady: Bool { manager?.state == .poweredOn }

    func start() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard let manager, manager.state == .poweredOn, !manager.isScanning else { return }
        // No service filter: a device that doesn't put the service UUID in its advertisement should
        // still be listable. Duplicates on, because Fluke devices advertise only every ~10 s and a
        // device has to keep refreshing its "last seen" time to stay in the list.
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() { manager?.stopScan() }

    func register(_ link: BLETransport, for id: UUID) { links[id] = WeakLink(link: link) }

    func peripheral(for id: UUID) -> CBPeripheral? {
        known[id] ?? manager?.retrievePeripherals(withIdentifiers: [id]).first
    }

    func connect(_ peripheral: CBPeripheral) {
        known[peripheral.identifier] = peripheral
        manager?.connect(peripheral)
    }

    func cancel(_ peripheral: CBPeripheral) { manager?.cancelPeripheralConnection(peripheral) }
}

extension BLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: radio = .poweredOn
        case .poweredOff: radio = .poweredOff
        case .unauthorized: radio = .unauthorized
        case .unsupported: radio = .unsupported
        default: radio = .unknown
        }
        onRadioChange?(radio)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // RSSI 127 means "not available"; skip those rather than draw a bogus signal strength.
        guard RSSI.intValue != 127 else { return }
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let advertises = services.contains(Self.serviceID)
        // Nameless devices that don't advertise the service are the bulk of any BLE environment: not listable.
        guard advertises || name != nil else { return }

        known[peripheral.identifier] = peripheral
        onDiscover?(DiscoveredMeter(
            id: peripheral.identifier,
            name: name ?? String(localized: "Fluke device"),
            rssi: RSSI.intValue,
            advertisesService: advertises,
            lastSeen: Date()
        ))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        links[peripheral.identifier]?.link?.handleDidConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.link?.handleDidFailToConnect(error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier]?.link?.handleDidDisconnect(peripheral, error: error)
    }
}

/// The Bluetooth link to one meter: an async wrapper around its peripheral and GATT table. Every
/// service and characteristic is discovered (and logged), because the table of a 1587 FC hasn't been
/// published anywhere; the Fluke reading service is then picked out by UUID. Everything runs on the
/// main queue, so delegate callbacks are main-actor isolated and there's no locking to get wrong.
///
/// The only thing this app ever writes is the one-byte connection ID (`writeConnectionID`); there is no
/// general write path, and the firmware-update characteristics are never touched.
@MainActor
final class BLETransport: NSObject {
    /// Link dropped (or failed while connecting). `nil` error = we asked for it.
    var onDisconnect: (@MainActor (Error?) -> Void)?
    /// Binary live reading notifications.
    var onBinaryReading: (@MainActor (Data) -> Void)?
    /// ASCII display notifications.
    var onAsciiReading: (@MainActor (Data) -> Void)?
    /// Any other characteristic value (Device Information and others): (UUID string, bytes).
    var onValue: (@MainActor (String, Data) -> Void)?
    /// The system re-connected on its own while a session was running (a queued connection request
    /// completed, or the link dropped and came back). The new link has no subscription, so the session
    /// is dead and must be rebuilt.
    var onLinkReestablished: (@MainActor () -> Void)?
    /// Connection milestones and the GATT table, for the diagnostics log.
    var onEvent: (@MainActor (String) -> Void)?

    private let central: BLECentral
    let id: UUID
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]
    private var services: [CBService] = []
    private var servicesAwaitingCharacteristics = 0
    /// Discovery has begun on the current link; a didConnect after that is the system re-connecting.
    private var discoveryStarted = false

    private var pending: (id: Int, continuation: CheckedContinuation<Void, Error>)?
    private var nextOperationID = 0
    private var disconnectRequested = false

    init(central: BLECentral, id: UUID) {
        self.central = central
        self.id = id
        super.init()
        central.register(self, for: id)
    }

    var isConnected: Bool { peripheral?.state == .connected && !services.isEmpty }

    func has(_ uuid: String) -> Bool { characteristics[uuid.uppercased()] != nil }

    /// For the diagnostics log when the stream goes quiet.
    var stateSummary: String {
        let raw = peripheral.map { String($0.state.rawValue) } ?? "none"
        let notifying = characteristics[FlukeUUID.binaryReading].map { String($0.isNotifying) } ?? "n/a"
        return "peripheral state=\(raw) (2=connected), reading characteristic notifying=\(notifying)"
    }

    /// Characteristics that can be read, by UUID string, in a stable order.
    var readableUUIDs: [String] {
        characteristics.filter { $0.value.properties.contains(.read) }.keys.sorted()
    }
    func hasService(_ uuid: String) -> Bool { services.contains { $0.uuid.uuidString.uppercased() == uuid.uppercased() } }

    // MARK: Connection

    /// Connects and discovers every service and characteristic.
    func connect(timeout: Double = 20) async throws {
        guard central.isReady else {
            throw MeterError.bluetoothUnavailable(String(localized: "Bluetooth is not available."))
        }
        guard let target = central.peripheral(for: id) else { throw MeterError.notConnected }
        disconnectRequested = false
        target.delegate = self
        peripheral = target
        clearGATT()

        // A link from an earlier session can still be closing. Let it finish rather than racing it (cancelling
        // and reconnecting back-to-back makes the meter drop each new link within seconds).
        if target.state == .disconnecting {
            onEvent?("peripheral is still disconnecting; waiting for it to finish")
            for _ in 0..<50 where target.state == .disconnecting { try await Task.sleep(for: .milliseconds(100)) }
        }

        do {
            if target.state == .connected {
                // Already linked (the system re-established it, or an earlier attempt completed late).
                // Use that link instead of tearing it down: just discover and subscribe again.
                onEvent?("peripheral already connected; reusing the link")
                discoveryStarted = true
                try await perform(timeout: timeout) { target.discoverServices(nil) }
            } else {
                onEvent?("connect() → \(target.identifier.uuidString) state=\(target.state.rawValue)")
                try await perform(timeout: timeout) { central.connect(target) }
            }
            onEvent?("GATT discovered: \(services.count) services, \(characteristics.count) characteristics")
        } catch {
            central.cancel(target)
            peripheral = nil
            clearGATT()
            throw error
        }
    }

    func disconnect() {
        disconnectRequested = true
        if let peripheral { central.cancel(peripheral) }
        failPending(MeterError.notConnected)
        peripheral = nil
        clearGATT()
    }

    // MARK: I/O (read-only)

    func setNotify(_ enabled: Bool, uuid: String, timeout: Double = 5) async throws {
        guard let peripheral, let characteristic = characteristics[uuid.uppercased()] else { throw MeterError.notConnected }
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            onEvent?("\(uuid) can't notify (props \(Self.describe(characteristic.properties)))")
            throw MeterError.noReadingCharacteristic
        }
        try await perform(timeout: timeout) { peripheral.setNotifyValue(enabled, for: characteristic) }
    }

    /// Writes the one-byte connection ID: the number the meter shows as "ID#" on its display. The only
    /// write this app makes; it resets to 0 when the link drops, so nothing persists on the meter.
    func writeConnectionID(_ id: UInt8, timeout: Double = 5) async throws {
        guard let peripheral, peripheral.state == .connected,
              let characteristic = characteristics[FlukeUUID.connectionID] else { throw MeterError.notConnected }
        guard characteristic.properties.contains(.write) else {
            onEvent?("connection ID characteristic isn't writable (props \(Self.describe(characteristic.properties)))")
            throw MeterError.noReadingCharacteristic
        }
        onEvent?("→ write connection ID \(id) to \(FlukeUUID.connectionID)")
        try await perform(timeout: timeout) { peripheral.writeValue(Data([id]), for: characteristic, type: .withResponse) }
    }

    /// Asks for a characteristic's value; the answer arrives through `onValue`.
    func read(_ uuid: String) {
        guard let peripheral, peripheral.state == .connected,
              let characteristic = characteristics[uuid.uppercased()],
              characteristic.properties.contains(.read) else { return }
        peripheral.readValue(for: characteristic)
    }

    // MARK: One-operation-at-a-time completion plumbing

    private func perform(timeout: Double, _ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let id = nextOperationID
            nextOperationID += 1
            pending = (id, continuation)
            start()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.pending?.id == id else { return }
                self.failPending(MeterError.timeout)
            }
        }
    }

    private func completePending() {
        guard let op = pending else { return }
        pending = nil
        op.continuation.resume()
    }

    private func failPending(_ error: Error) {
        guard let op = pending else { return }
        pending = nil
        op.continuation.resume(throwing: error)
    }

    private func clearGATT() {
        characteristics = [:]
        services = []
        servicesAwaitingCharacteristics = 0
        discoveryStarted = false
    }

    private static func describe(_ props: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "write-no-rsp"), (.notify, "notify"),
            (.indicate, "indicate"), (.broadcast, "broadcast"), (.authenticatedSignedWrites, "signed-write"),
        ]
        let list = names.filter { props.contains($0.0) }.map(\.1)
        return list.isEmpty ? "none" : list.joined(separator: ",")
    }

    // MARK: Events routed from BLECentral

    func handleDidConnect(_ peripheral: CBPeripheral) {
        // CoreBluetooth can deliver a second didConnect for a request that was queued while the
        // peripheral was still disconnecting; the link is already up, so there's nothing to redo.
        if discoveryStarted {
            if services.isEmpty {
                onEvent?("didConnect during discovery: ignored")
            } else {
                // The system re-connected under a running session. That link has no subscription, so the
                // session must be rebuilt on top of it (without cancelling it).
                onEvent?("didConnect while a session was running: link re-established; session must restart")
                onLinkReestablished?()
            }
            return
        }
        onEvent?("didConnect; discovering services")
        discoveryStarted = true
        peripheral.discoverServices(nil)
    }

    func handleDidFailToConnect(_ error: Error?) {
        onEvent?("didFailToConnect: \(String(describing: error))")
        failPending(error ?? MeterError.notConnected)
    }

    func handleDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        onEvent?("didDisconnect: \(String(describing: error))")
        guard peripheral === self.peripheral else { return }
        let requested = disconnectRequested
        failPending(error ?? MeterError.notConnected)
        self.peripheral = nil
        clearGATT()
        onDisconnect?(requested ? nil : (error ?? MeterError.notConnected))
    }
}

extension BLETransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onEvent?("service discovery failed: \(error.localizedDescription)")
            return failPending(error)
        }
        let found = peripheral.services ?? []
        services = found
        onEvent?("services: " + (found.isEmpty ? "none" : found.map { $0.uuid.uuidString }.joined(separator: ", ")))
        guard !found.isEmpty else { return failPending(MeterError.notAFlukeDevice) }
        servicesAwaitingCharacteristics = found.count
        for service in found { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            onEvent?("characteristic discovery failed for \(service.uuid.uuidString): \(error.localizedDescription)")
        } else {
            onEvent?("service \(service.uuid.uuidString)")
            for characteristic in service.characteristics ?? [] {
                let uuid = characteristic.uuid.uuidString.uppercased()
                characteristics[uuid] = characteristic
                let warning = FlukeUUID.firmwareUpdateWarning.contains(uuid) ? "  (firmware update: never touched)" : ""
                onEvent?("  \(uuid)  [\(Self.describe(characteristic.properties))]\(warning)")
            }
        }
        servicesAwaitingCharacteristics -= 1
        if servicesAwaitingCharacteristics <= 0 { completePending() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        onEvent?("notify \(characteristic.uuid.uuidString) on=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
        if let error { failPending(error) } else { completePending() }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        onEvent?("write \(characteristic.uuid.uuidString) \(error.map { "failed: \($0.localizedDescription)" } ?? "acknowledged")")
        if let error { failPending(error) } else { completePending() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        if let error {
            onEvent?("value \(uuid) failed: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        switch uuid {
        case FlukeUUID.binaryReading: onBinaryReading?(value)
        case FlukeUUID.asciiReading: onAsciiReading?(value)
        default: onValue?(uuid, value)
        }
    }
}
