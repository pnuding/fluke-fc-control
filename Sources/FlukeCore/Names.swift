import Foundation

// Code tables for the binary reading record. Values and names follow the community
// `fluke-connect-client` crate (verified on an IR3000 FC + Fluke 289; everything else is
// documented but not exercised on real hardware, including the 1587 FC).

/// SI magnitude prefix of the displayed number (3 bits).
public enum Magnitude: Equatable, Sendable {
    case none, giga, mega, kilo, milli, micro, nano, pico

    public init(raw: UInt8) {
        switch raw {
        case 1: self = .giga
        case 2: self = .mega
        case 3: self = .kilo
        case 4: self = .milli
        case 5: self = .micro
        case 6: self = .nano
        case 7: self = .pico
        default: self = .none
        }
    }

    public var exponent: Int {
        switch self {
        case .none: 0
        case .giga: 9
        case .mega: 6
        case .kilo: 3
        case .milli: -3
        case .micro: -6
        case .nano: -9
        case .pico: -12
        }
    }

    public var symbol: String {
        switch self {
        case .none: ""
        case .giga: "G"
        case .mega: "M"
        case .kilo: "k"
        case .milli: "m"
        case .micro: "µ"
        case .nano: "n"
        case .pico: "p"
        }
    }
}

/// Reading state (4 bits). Anything but `.normal` shouldn't be trusted as a measurement.
public enum ReadingState: Equatable, Sendable {
    case normal, blank, inactive, invalid, overRange, overloadA2D, openThermocouple
    case discharge, leads, greaterThan, missingPhase, error, lessThan, empty
    case unknown(UInt8)

    public init(raw: UInt8) {
        switch raw {
        case 0: self = .normal
        case 1: self = .blank
        case 2: self = .inactive
        case 3: self = .invalid
        case 4: self = .overRange
        case 5: self = .overloadA2D
        case 6: self = .openThermocouple
        case 7: self = .discharge
        case 8: self = .leads
        case 9: self = .greaterThan
        case 10: self = .missingPhase
        case 11: self = .error
        case 12: self = .lessThan
        case 13: self = .empty
        default: self = .unknown(raw)
        }
    }

    /// States that carry a number worth showing.
    public var hasNumber: Bool {
        switch self {
        case .normal, .greaterThan, .lessThan: true
        default: false
        }
    }

    /// Over-range / overload: the meter shows "OL".
    public var isOverload: Bool { self == .overRange || self == .overloadA2D }

    /// What to show instead of a number, for states that have no number.
    public var placeholder: String? {
        switch self {
        case .normal, .greaterThan, .lessThan: nil
        case .overRange, .overloadA2D: "OL"
        case .blank, .inactive, .invalid, .empty, .unknown: "----"
        case .openThermocouple: "OPEN"
        case .discharge: "diSC"
        case .leads: "LEAd"
        case .missingPhase: "PHASE"
        case .error: "Err"
        }
    }
}

/// Qualifier on a reading (5 bits): short/open circuit, good diode, hazardous voltage…
public enum Attribute {
    public static func name(_ code: UInt8) -> String? {
        switch code {
        case 0: nil
        case 1: String(localized: "Open circuit")
        case 2: String(localized: "Short circuit")
        case 3: String(localized: "Glitch")
        case 4: String(localized: "Good diode")
        case 5: String(localized: "Negative edge")
        case 6: String(localized: "Positive edge")
        case 7: String(localized: "High current")
        case 8: String(localized: "Hazardous voltage")
        case 9: String(localized: "Low ohms")
        case 10: String(localized: "Open glitch")
        case 11: String(localized: "Short glitch")
        case 12: String(localized: "Peak")
        case 13: String(localized: "Sourced")
        case 14: String(localized: "Simulated")
        case 15: String(localized: "Noise")
        case 16: String(localized: "Breakdown")
        default: String(localized: "Attribute \(String(code))")
        }
    }

    /// Worth drawing the eye to.
    public static func isWarning(_ code: UInt8) -> Bool { code == 8 || code == 7 || code == 16 }
}

public struct UnitInfo: Equatable, Sendable {
    /// What follows the number and its SI prefix: "V", "Ω", "°C".
    public let symbol: String
    /// "AC", "DC" or "AC+DC" for electrical units that have one.
    public let qualifier: String?
    /// Power of ten the raw number must be scaled by to reach the base unit (TΩ, mm/s, µm).
    public let baseExponent: Int

    /// "V DC": the unit with its qualifier, for chart titles and CSV columns.
    public var label: String { qualifier.map { "\(symbol) \($0)" } ?? symbol }

    public static func lookup(_ code: UInt8) -> UnitInfo {
        func plain(_ symbol: String, exponent: Int = 0) -> UnitInfo { UnitInfo(symbol: symbol, qualifier: nil, baseExponent: exponent) }
        func qualified(_ symbol: String, _ qualifier: String) -> UnitInfo { UnitInfo(symbol: symbol, qualifier: qualifier, baseExponent: 0) }
        switch code {
        case 0: return plain("")
        case 1: return qualified("V", "AC")
        case 2: return qualified("V", "DC")
        case 3: return qualified("A", "AC")
        case 4: return qualified("A", "DC")
        case 5: return plain("Hz")
        case 6: return plain("%RH")
        case 7: return plain("°C")
        case 8: return plain("°F")
        case 9: return plain("°R")
        case 10: return plain("K")
        case 11: return plain("Ω")
        case 12: return plain("S")
        case 13: return plain("%")
        case 14: return plain("s")
        case 15: return plain("F")
        case 16: return plain("dB")
        case 17: return plain("dBm")
        case 18: return plain("W")
        case 19: return plain("J")
        case 20: return plain("H")
        case 21: return plain("psi")
        case 22: return plain("mHg")
        case 23: return plain("inHg")
        case 24: return plain("ftH₂O")
        case 25: return plain("mH₂O")
        case 26: return plain("inH₂O")
        case 27: return plain("inH₂O@60°F")
        case 28: return plain("bar")
        case 29: return plain("Pa")
        case 30: return plain("g/cm²")
        case 31: return plain("dBV")
        case 32: return plain("CF")
        case 33: return qualified("V", "AC+DC")
        case 34: return qualified("A", "AC+DC")
        case 35: return plain("%")
        case 36: return plain("V/Hz")
        case 37: return plain("g")
        case 38: return plain("m/s²")
        case 39: return plain("in/s")
        case 40: return plain("mm/s", exponent: -3)
        case 41: return plain("mil")
        case 42: return plain("µm", exponent: -6)
        case 44: return plain("TΩ", exponent: 12)
        default: return plain("?")
        }
    }
}

public enum FunctionName {
    /// The function the meter is set to, as shown in the card's header. Each name is a localizable string.
    private static let names: [LocalizedStringResource] = [
            "No function", "AC Millivolts", "AC Voltage", "AC+DC Voltage", "AC Millivolts (average)", "AC Voltage (average)",
            "AC+DC Voltage (average)", "AC Voltage (LoZ)", "AC Millivolts (low-pass)", "AC Voltage (low-pass)",
            "DC Microvolts", "DC Millivolts", "DC Voltage", "AC Milliamps", "AC Current", "AC+DC Current",
            "AC Milliamps (average)", "AC Current (average)", "AC+DC Current (average)", "DC Microamps", "DC Milliamps",
            "DC Current", "Frequency (mV AC)", "Frequency (V AC)", "Frequency (mV AC, low-pass)", "Frequency (V AC, low-pass)",
            "Frequency (mV DC)", "Frequency (V DC)", "Frequency (µA AC)", "Frequency (mA AC)", "Frequency (A AC)",
            "Frequency (µA DC)", "Frequency (mA DC)", "Frequency (A DC)", "Temperature", "Temperature (°F)",
            "Temperature (°C)", "Temperature (°R)", "Temperature (K)", "Continuity", "Resistance", "Conductance",
            "Low Ohms", "Phase", "AC Inrush Current", "Capacitance", "Diode Test", "AC Volts per Hertz",
            "AC+DC Millivolts", "AC+DC Milliamps", "AC Microamps", "AC+DC Microamps", "Test Voltage", "Fault Voltage",
            "Touch Voltage Limit", "Insulation", "Continuity (+)", "Continuity (−)", "Continuity (average)",
            "Loop Impedance (trip)", "Loop Impedance (no trip)", "Loop Impedance", "Loop Impedance (max)",
            "Line Impedance", "Line Impedance (max)", "RCD Trip Time", "RCD Trip Time (auto)", "RCD Ramp",
            "Phase Rotation", "Earth Resistance", "Earth Fault Current", "Short-Circuit Current", "Auto Test",
            "Insulation Spot (detecting voltage)", "Insulation Spot Test", "Polarization Index (detecting voltage)",
            "Polarization Index Test", "Polarization Index", "DAR (detecting voltage)", "DAR Test", "DAR",
            "Ramp (detecting voltage)", "Ramp Test", "DAR China (detecting voltage)", "DAR China Test", "DAR China",
            "Pressure", "Field Sense",
    ]

    public static func name(_ code: UInt8) -> String {
        Int(code) < names.count ? String(localized: names[Int(code)]) : String(localized: "Function \(String(code))")
    }
}
