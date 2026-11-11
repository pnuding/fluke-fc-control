import Testing
@testable import FlukeCore

// No Foundation import: the Command Line Tools' Swift Testing has no `_Testing_Foundation` overlay.

private func bytes(_ hex: String) -> [UInt8] {
    hex.split(separator: " ").map { UInt8($0, radix: 16)! }
}

private func near(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= abs(b) * 1e-9 + 1e-15
}

@Suite struct BinaryRecordTests {
    // Vectors from the community docs (captures on an IR3000 FC + Fluke 289).

    @Test func temperatureFahrenheit() throws {
        let r = try #require(Reading(record: bytes("01 03 00 02 08 22 00 00")))
        #expect(r.counts == 769)
        #expect(r.decimals == 1)
        #expect(r.state == .normal)
        #expect(r.unitCode == 8)
        #expect(r.functionCode == 34)
        #expect(r.numberText == "76.9")
        #expect(r.unitSymbol == "°F")
    }

    @Test func negativeMillivolts() throws {
        let r = try #require(Reading(record: bytes("34 00 00 c6 02 0b 00 00")))
        #expect(r.isNegative)
        #expect(r.magnitude == .milli)
        #expect(r.numberText == "-0.052")
        #expect(r.unitSymbol == "mV")
        #expect(r.unit.label == "V DC")
        #expect(near(r.value, -0.000052))
    }

    @Test func plainVoltsDC() throws {
        let r = try #require(Reading(record: bytes("d9 c5 00 08 02 0c 00 00")))
        #expect(r.numberText == "5.0649")
        #expect(r.unitSymbol == "V")
        #expect(r.functionName == "DC Voltage")
        #expect(near(r.value, 5.0649))
    }

    @Test func overloadHasNoNumber() throws {
        let r = try #require(Reading(record: bytes("ff ff 9f 42 0f 2d 00 00")))
        #expect(r.state == .overRange)
        #expect(r.state.isOverload)
        #expect(r.numberText == nil)
        #expect(r.displayText == "OL")
        #expect(r.value == nil)
        #expect(r.functionName == "Capacitance")
    }

    @Test func blankWhileAutoRanging() throws {
        let r = try #require(Reading(record: bytes("ff ff 3f 22 0b 28 00 00")))
        #expect(r.state == .blank)
        #expect(r.displayText == "----")
    }

    @Test func noReadingState() throws {
        let r = try #require(Reading(record: bytes("ff ff 7f 00 00 0c 00 00")))
        #expect(r.state == .invalid)
        #expect(r.displayText == "----")
    }

    @Test func lowOhms() throws {
        let r = try #require(Reading(record: bytes("88 13 00 06 0b 2a 00 00")))
        #expect(r.counts == 5000)
        #expect(r.decimals == 3)
        #expect(r.numberText == "5.000")
        #expect(r.unitSymbol == "Ω")
        #expect(r.functionName == "Low Ohms")
    }

    @Test func continuityShortCircuitAttribute() throws {
        let r = try #require(Reading(record: bytes("d5 01 00 04 0b 27 00 08")))
        #expect(r.numberText == "4.69")
        #expect(r.attributeCode == 2)
        #expect(r.attribute == "Short circuit")
        #expect(r.functionName == "Continuity")
    }

    // Vectors from the crate's own README tests.
    @Test func readmeExamples() throws {
        let volts = try #require(Reading(record: [0x5C, 0x00, 0x00, 0x02, 0x02, 0x0C, 0x00, 0x00]))
        #expect(volts.numberText == "9.2")
        #expect(volts.unitSymbol == "V")

        let millivolts = try #require(Reading(record: [0x54, 0x15, 0x00, 0x42, 0x02, 0x0C, 0x06, 0x01]))
        #expect(millivolts.numberText == "546.0")
        #expect(millivolts.unitSymbol == "mV")
        #expect(millivolts.range == 6)
        #expect(millivolts.decade == 2)
        #expect(!millivolts.capture)
    }

    @Test func tooShortIsIgnored() {
        #expect(Reading(record: bytes("01 03 00")) == nil)
        #expect(ReadingPacket(payload: bytes("01 03 00 02 08 22 00")) == nil)
    }

    @Test func leadingZerosKeepTheirPlace() {
        // 52 counts, 3 decimals: 0.052, not .52 or 0.52
        #expect(Reading(counts: 52, decimals: 3).numberText == "0.052")
        #expect(Reading(counts: 0, decimals: 2).numberText == "0.00")
        #expect(Reading(counts: 7).numberText == "7")
    }

    @Test func greaterAndLessThanKeepTheirNumber() {
        #expect(Reading(counts: 600, state: .greaterThan, decimals: 1).numberText == "> 60.0")
        #expect(Reading(counts: 5, state: .lessThan).numberText == "< 5")
    }

    @Test func insulationInMegohmsAndGigohms() {
        // 1587 FC insulation test: function 55, ohms, mega/giga prefix.
        let mega = Reading(counts: 5000, decimals: 1, magnitude: .mega, unitCode: 11, functionCode: 55)
        #expect(mega.numberText == "500.0")
        #expect(mega.unitSymbol == "MΩ")
        #expect(near(mega.value, 500e6))
        #expect(mega.functionName == "Insulation")

        let giga = Reading(counts: 1234, decimals: 3, magnitude: .giga, unitCode: 11, functionCode: 55)
        #expect(near(giga.value, 1.234e9))
    }

    @Test func teraohmUnitScalesToOhms() {
        let r = Reading(counts: 25, decimals: 1, unitCode: 44)
        #expect(r.unitSymbol == "TΩ")
        #expect(near(r.value, 2.5e12))
    }

    @Test func counterSentinelWithNormalStateHasNoNumber() {
        let r = Reading(counts: Reading.noValueCounts, state: .normal)
        #expect(r.numberText == nil)
        #expect(r.value == nil)
    }
}

@Suite struct PacketTests {
    @Test func eightBytesIsPrimaryOnly() throws {
        let p = try #require(ReadingPacket(payload: bytes("d9 c5 00 08 02 0c 00 00")))
        #expect(p.secondary == nil)
        #expect(p.primary.numberText == "5.0649")
    }

    @Test func allZeroSecondaryMeansNone() throws {
        let p = try #require(ReadingPacket(payload: bytes("b4 c5 00 08 02 0c 00 00 00 00 00 00 00 00 00 00")))
        #expect(p.secondary == nil)
        #expect(p.primary.numberText == "5.0612")
    }

    @Test func sixteenBytesCarriesSecondary() throws {
        // V AC LoZ: 0.0 V AC primary, 0.0 V DC secondary.
        let p = try #require(ReadingPacket(payload: bytes("00 00 00 02 01 07 00 00 00 00 00 02 02 07 00 00")))
        #expect(p.primary.unitCode == 1)
        #expect(p.primary.numberText == "0.0")
        let secondary = try #require(p.secondary)
        #expect(secondary.unitCode == 2)
        #expect(secondary.functionName == "AC Voltage (LoZ)")
    }

    @Test func longerPayloadsDecodeTheFirstRecord() throws {
        let eighteen = bytes("d9 c5 00 08 02 0c 00 00") + [UInt8](repeating: 0, count: 10)
        let p = try #require(ReadingPacket(payload: eighteen))
        #expect(p.primary.numberText == "5.0649")
    }
}

@Suite struct AsciiTests {
    /// Builds a 17-byte payload: format byte, then reading(6) multiplier(1) unit(4) coupling(2) bolt(1) inrush(2).
    private func ascii(number: String, multiplier: String = " ", unit: String = "", coupling: String = "") -> [UInt8] {
        func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, width - text.count))
            return left ? fill + text : text + fill
        }
        let text = pad(number, 6, left: true) + multiplier + pad(unit, 4) + pad(coupling, 2) + "   "
        return [0x00] + Array(text.utf8)
    }

    @Test func clampVolts() throws {
        // "   9.2 V\0  dc   ": from a 376 FC capture, NUL after the unit
        var payload: [UInt8] = [0x00] + Array("   9.2 V".utf8) + [0x00, 0x20, 0x20] + Array("dc".utf8) + [0x20, 0x20, 0x20]
        #expect(payload.count == 17)
        let r = try #require(AsciiReading.parse(payload))
        #expect(r.numberText == "9.2")
        #expect(r.unit.label == "V DC")
        payload[0] = 0x01
        #expect(AsciiReading.parse(payload)?.numberText == "9.2")
    }

    @Test func microfarads() throws {
        let r = try #require(AsciiReading.parse(ascii(number: "0.0", multiplier: "u", unit: "F")))
        #expect(r.numberText == "0.0")
        #expect(r.unitSymbol == "µF")
    }

    @Test func acVoltsPicksTheACUnit() throws {
        let r = try #require(AsciiReading.parse(ascii(number: "230.1", unit: "V", coupling: "ac")))
        #expect(r.unit.label == "V AC")
    }

    @Test func overloadAndBlank() throws {
        let ol = try #require(AsciiReading.parse(ascii(number: "OL", unit: "V", coupling: "dc")))
        #expect(ol.state == .overRange)
        let blank = try #require(AsciiReading.parse(ascii(number: "----", unit: "V", coupling: "dc")))
        #expect(blank.state == .blank)
    }

    @Test func negative() throws {
        let r = try #require(AsciiReading.parse(ascii(number: "-0.758", multiplier: "m", unit: "V", coupling: "dc")))
        #expect(r.isNegative)
        #expect(r.numberText == "-0.758")
        #expect(r.unitSymbol == "mV")
    }

    @Test func shortPayloadIgnored() {
        #expect(AsciiReading.parse([0x00, 0x20]) == nil)
    }
}

@Suite struct TableTests {
    @Test func functionTableAlignsWithTheWireCodes() {
        #expect(FunctionName.name(12) == "DC Voltage")
        #expect(FunctionName.name(40) == "Resistance")
        #expect(FunctionName.name(45) == "Capacitance")
        #expect(FunctionName.name(46) == "Diode Test")
        #expect(FunctionName.name(52) == "Test Voltage")
        #expect(FunctionName.name(55) == "Insulation")
        #expect(FunctionName.name(86) == "Pressure")
        #expect(FunctionName.name(87) == "Field Sense")
        #expect(FunctionName.name(200) == "Function 200")
    }

    @Test func magnitudeAndStateTables() {
        #expect(Magnitude(raw: 2).symbol == "M")
        #expect(Magnitude(raw: 5).exponent == -6)
        #expect(ReadingState(raw: 4) == .overRange)
        #expect(ReadingState(raw: 14) == .unknown(14))
    }

    @Test func connectionIDsAreAssignedLowestFreeFirst() {
        #expect(ConnectionID.next(avoiding: [Int]()) == 1)
        #expect(ConnectionID.next(avoiding: [1]) == 2)
        #expect(ConnectionID.next(avoiding: [1, 2, 4]) == 3)
        #expect(ConnectionID.next(avoiding: [2, 3]) == 1)
        #expect(ConnectionID.next(avoiding: Array(1...255)) == nil)
    }

    @Test func uuidsUseTheVendorBase() {
        #expect(FlukeUUID.readingService == "B6981800-7562-11E2-B50D-00163E46F8FE")
        #expect(FlukeUUID.binaryReading == "B698290F-7562-11E2-B50D-00163E46F8FE")
        #expect(FlukeUUID.connectionID == "B6982902-7562-11E2-B50D-00163E46F8FE")
    }

    @Test func deviceInfoParsesStrings() {
        var info = DeviceInfo()
        info.absorb(uuid: "2a24", value: [0x46, 0x4C, 0x55, 0x4B, 0x45, 0x20, 0x32, 0x38, 0x39, 0x00].asData)
        #expect(info.model == "FLUKE 289")
        #expect(info.absorb(uuid: "FFFF", value: [1].asData) == false)
    }
}

private extension Array where Element == UInt8 {
    var asData: TestData { TestData(self) }
}
