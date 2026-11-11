import Foundation

/// One decoded reading: what the meter's display shows right now.
///
/// Wire format (characteristic `B698290F`, little-endian, 8 bytes per record):
///
///     word 0: bits  0–20 counts (0x1FFFFF = no value)  21–24 state  25–27 decimals
///                  28–30 SI prefix  31 sign (1 = negative)
///     word 1: bits  0–7 unit  8–15 function  16–22 range  23–25 decade
///                  26–30 attribute  31 capture flag
///
/// The displayed number is `counts` with `decimals` digits after the point, in the unit with the
/// SI prefix, exactly as on the meter. `range` and `decade` stay 0 on the one device that has
/// been tested, so they're kept but not interpreted.
public struct Reading: Equatable, Sendable {
    public var counts: UInt32
    public var state: ReadingState
    public var decimals: Int
    public var magnitude: Magnitude
    public var isNegative: Bool
    public var unitCode: UInt8
    public var functionCode: UInt8
    public var range: UInt8
    public var decade: UInt8
    public var attributeCode: UInt8
    public var capture: Bool

    public static let noValueCounts: UInt32 = 0x1F_FFFF

    public init(counts: UInt32, state: ReadingState = .normal, decimals: Int = 0, magnitude: Magnitude = .none,
                isNegative: Bool = false, unitCode: UInt8 = 0, functionCode: UInt8 = 0, range: UInt8 = 0,
                decade: UInt8 = 0, attributeCode: UInt8 = 0, capture: Bool = false) {
        self.counts = counts
        self.state = state
        self.decimals = decimals
        self.magnitude = magnitude
        self.isNegative = isNegative
        self.unitCode = unitCode
        self.functionCode = functionCode
        self.range = range
        self.decade = decade
        self.attributeCode = attributeCode
        self.capture = capture
    }

    /// Decodes one 8-byte record. `nil` if there are fewer than 8 bytes.
    public init?(record bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        let low = word(0), high = word(4)
        self.init(
            counts: low & 0x1F_FFFF,
            state: ReadingState(raw: UInt8((low >> 21) & 0xF)),
            decimals: Int((low >> 25) & 0x7),
            magnitude: Magnitude(raw: UInt8((low >> 28) & 0x7)),
            isNegative: (low >> 31) & 1 == 1,
            unitCode: UInt8(high & 0xFF),
            functionCode: UInt8((high >> 8) & 0xFF),
            range: UInt8((high >> 16) & 0x7F),
            decade: UInt8((high >> 23) & 0x7),
            attributeCode: UInt8((high >> 26) & 0x1F),
            capture: (high >> 31) & 1 == 1
        )
    }

    // MARK: Derived

    public var unit: UnitInfo { UnitInfo.lookup(unitCode) }
    public var attribute: String? { Attribute.name(attributeCode) }

    /// True when `counts` is the "no value" sentinel or the state carries no number.
    public var hasNumber: Bool { state.hasNumber && counts != Self.noValueCounts }

    /// The number exactly as displayed: sign, counts with `decimals` decimals ("-0.052", "5.0649").
    /// `nil` when the meter has no number to show (OL, blank, open thermocouple…).
    public var numberText: String? {
        guard hasNumber else { return nil }
        var digits = String(counts)
        if decimals > 0 {
            if digits.count <= decimals { digits = String(repeating: "0", count: decimals - digits.count + 1) + digits }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -decimals))
        }
        let prefix = state == .greaterThan ? "> " : state == .lessThan ? "< " : ""
        return prefix + (isNegative ? "-" : "") + digits
    }

    /// What replaces the number when there isn't one ("OL", "----").
    public var placeholder: String { state.placeholder ?? (counts == Self.noValueCounts ? "----" : "") }

    /// Number or placeholder, whichever applies.
    public var displayText: String { numberText ?? placeholder }

    /// SI prefix + unit symbol as the meter shows it next to the number: "mV", "MΩ", "°C".
    public var unitSymbol: String { magnitude.symbol + unit.symbol }

    /// The value in the unit's base (V, A, Ω…), for graphing. `nil` unless there's a real number;
    /// over-range readings have no value (the graph shows a gap).
    public var value: Double? {
        guard hasNumber else { return nil }
        let exponent = magnitude.exponent - decimals + unit.baseExponent
        let magnitudeValue = Double(counts) * pow(10, Double(exponent))
        return isNegative ? -magnitudeValue : magnitudeValue
    }

    /// Header text: the meter's function, or the unit when the function is unknown to us.
    public var functionName: String {
        functionCode == 0 ? unit.label : FunctionName.name(functionCode)
    }
}

/// One BLE notification on the reading characteristic: a primary reading and, on some devices, a
/// secondary one (the IR3000 FC sends 16 bytes; the 3000 FC and the clamp meters send 8).
public struct ReadingPacket: Equatable, Sendable {
    public var primary: Reading
    public var secondary: Reading?

    /// Payloads shorter than 8 bytes are ignored. Longer ones decode their first 8 bytes, plus a
    /// second record when the payload is at least 16 bytes. An all-zero secondary means "none".
    public init?(payload: [UInt8]) {
        guard let primary = Reading(record: payload) else { return nil }
        self.primary = primary
        if payload.count >= 16, payload[8..<16].contains(where: { $0 != 0 }) {
            secondary = Reading(record: Array(payload[8..<16]))
        } else {
            secondary = nil
        }
    }

    public init?(payload: Data) { self.init(payload: [UInt8](payload)) }
}

/// The ASCII display characteristic (`B6982901`): a format byte, then 16 characters. Documented
/// from public captures of 376 FC / 902 FC clamp meters only, so it is a fallback used when a
/// device sends nothing on the binary characteristic.
///
///     chars 0–5 reading (right-justified)  6 multiplier (n u m k M or space)
///           7–10 unit (V A OHMS DEGC DEGF H VHZ F R)  11–12 "ac"/"dc"  13 bolt "*"  14–15 inrush "in"
public enum AsciiReading {
    public static func parse(_ payload: [UInt8]) -> Reading? {
        guard payload.count >= 17 else { return nil }
        func field(_ range: Range<Int>) -> String {
            String(decoding: payload[(1 + range.lowerBound)..<(1 + range.upperBound)].filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
        let number = field(0..<6)
        let multiplier = field(6..<7)
        let unitText = field(7..<11)
        let coupling = field(11..<13).lowercased()

        let magnitude: Magnitude = switch multiplier {
        case "n": .nano
        case "u": .micro
        case "m": .milli
        case "k": .kilo
        case "M": .mega
        default: .none
        }
        let unitCode: UInt8 = switch unitText {
        case "V": coupling == "ac" ? 1 : 2
        case "A": coupling == "ac" ? 3 : 4
        case "OHMS": 11
        case "DEGC": 7
        case "DEGF": 8
        case "H", "VHZ": unitText == "H" ? 5 : 36
        case "F": 15
        case "R": 9
        default: 43
        }

        if number.uppercased() == "OL" {
            return Reading(counts: Reading.noValueCounts, state: .overRange, magnitude: magnitude, unitCode: unitCode)
        }
        let negative = number.hasPrefix("-")
        let unsigned = number.trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
        guard !unsigned.isEmpty, unsigned.allSatisfy({ $0.isNumber || $0 == "." }),
              unsigned.filter({ $0 == "." }).count <= 1 else {
            return Reading(counts: Reading.noValueCounts, state: .blank, magnitude: magnitude, unitCode: unitCode)
        }
        let parts = unsigned.split(separator: ".", omittingEmptySubsequences: false)
        let decimals = parts.count == 2 ? parts[1].count : 0
        guard decimals <= 7, let counts = UInt32(parts.joined()), counts < Reading.noValueCounts else { return nil }
        return Reading(counts: counts, decimals: decimals, magnitude: magnitude, isNegative: negative, unitCode: unitCode)
    }

    public static func parse(_ payload: Data) -> Reading? { parse([UInt8](payload)) }
}

public extension Array where Element == UInt8 {
    /// "01 03 00 02": for the diagnostics log.
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
