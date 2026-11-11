import Foundation

/// What the Device Information service says about the connected device. (The Battery Level characteristic is
/// deliberately not used: the 1587 FC reports a constant 100 % whatever its batteries are doing.)
public struct DeviceInfo: Equatable, Sendable {
    public var model: String?
    public var serial: String?
    public var firmware: String?
    public var software: String?
    public var manufacturer: String?
    public var name: String?

    public init() {}

    public var isEmpty: Bool {
        [model, serial, firmware, software, manufacturer, name].allSatisfy { $0 == nil }
    }

    /// Absorbs the value of a standard characteristic, identified by its 16-bit UUID string
    /// ("2A24"). Returns false when the UUID isn't one of ours.
    @discardableResult
    public mutating func absorb(uuid: String, value: Data) -> Bool {
        func text() -> String? {
            let s = String(decoding: value, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespaces))
            return s.isEmpty ? nil : s
        }
        switch uuid.uppercased() {
        case FlukeUUID.modelNumber: model = text()
        case FlukeUUID.serialNumber: serial = text()
        case FlukeUUID.firmwareRevision: firmware = text()
        case FlukeUUID.softwareRevision: software = text()
        case FlukeUUID.manufacturerName: manufacturer = text()
        case FlukeUUID.deviceName: name = text()
        default: return false
        }
        return true
    }
}
