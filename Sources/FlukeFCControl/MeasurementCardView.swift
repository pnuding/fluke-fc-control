import FlukeCore
import SwiftUI

/// The live readout: what the meter's display shows, plus a second line when the device sends one
/// (an insulation test's test voltage, for instance).
///
/// The meter decides the digits: its reading arrives as counts + decimals + SI prefix, so the number
/// here is the number on the meter's own display. The function is chosen on the meter, so the name
/// in the header is a label, not a control.
struct MeasurementCardView: View {
    let meter: FlukeMeter?

    private static let numberWidth: CGFloat = 320
    private static let unitWidth: CGFloat = 70

    private struct Status {
        var message = ""
        var isError = false
        /// Connected, but the meter has gone quiet: the number is still what the meter shows, just not live.
        var dimmed = false
        /// Show dashes instead of whatever was last received.
        var placeholder = false
    }

    var body: some View {
        // Ticks once a second purely to re-check "has it been too long since the last reading".
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = status(at: context.date)
            VStack(alignment: .leading, spacing: 0) {
                header(placeholder: status.placeholder)
                readingRow(status: status)
                    .padding(.top, 12)
                if let secondary = meter?.secondary, !status.placeholder {
                    secondaryRow(secondary, dimmed: status.dimmed)
                        .padding(.top, 8)
                }
                // Reserved height regardless of content, so a message appearing never resizes the card.
                Text(status.message.isEmpty ? " " : status.message)
                    .font(.callout)
                    .foregroundStyle(status.isError ? .red : .secondary)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .leading)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .frame(width: 16 + Self.numberWidth + 8 + Self.unitWidth + 16, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .glassCard(.regular.tint(Color.fluke.opacity(0.09)), in: .rect(cornerRadius: 20))
        }
    }

    // MARK: Status

    private func status(at now: Date) -> Status {
        guard let meter else {
            return Status(message: String(localized: "No meter selected. Click the Bluetooth button to choose one."), placeholder: true)
        }
        switch meter.link {
        case .idle:
            return Status(message: String(localized: "Not connected."), placeholder: true)
        case .bluetoothUnavailable(let message):
            return Status(message: message, isError: true, placeholder: true)
        case .connecting:
            return Status(message: String(localized: "Connecting to \(meter.name)…"), placeholder: true)
        case .retrying:
            return Status(message: String(localized: "Connection lost. Reconnecting…"), placeholder: true)
        case .connected:
            guard let last = meter.lastReadingAt else {
                return Status(message: String(localized: "Connected. Waiting for readings…"), placeholder: true)
            }
            if now.timeIntervalSince(last) > 5 {
                // The last value stays up, dimmed: it's the last thing the meter's display showed.
                return Status(message: String(localized: "No new readings. Is the meter asleep or out of range?"), dimmed: true)
            }
            return Status()
        }
    }

    // MARK: Header

    private func header(placeholder: Bool) -> some View {
        HStack(spacing: 8) {
            if !placeholder, let reading = meter?.reading, let attribute = reading.attribute {
                badge(attribute, warning: Attribute.isWarning(reading.attributeCode))
            }
            Spacer()
            Text(headerTitle(placeholder: placeholder))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                // Long function names in some languages ("Eristyspistemittaus (jännitteen tunnistus)") next to a
                // badge: shrink a little before cutting anything off.
                .minimumScaleFactor(0.7)
        }
        .frame(height: 24)
    }

    private func headerTitle(placeholder: Bool) -> String {
        if !placeholder, let reading = meter?.reading { return reading.functionName }
        return meter?.name ?? "Fluke FC"
    }

    private func badge(_ text: String, warning: Bool) -> some View {
        HStack(spacing: 4) {
            if warning { Image(systemName: "exclamationmark.triangle.fill") }
            Text(text)
        }
        .font(.caption2.weight(warning ? .semibold : .regular))
        .foregroundStyle(warning ? Color.orange : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((warning ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
    }

    // MARK: Readings

    private func readingRow(status: Status) -> some View {
        let reading = status.placeholder ? nil : meter?.reading
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(reading?.displayText ?? "----")
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .frame(width: Self.numberWidth, alignment: .trailing)
            Text(reading?.unitSymbol ?? " ")
                .font(.title2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: Self.unitWidth, alignment: .leading)
        }
        .opacity(status.dimmed ? 0.45 : 1)
    }

    private func secondaryRow(_ reading: Reading, dimmed: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(reading.functionName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(reading.displayText)
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(reading.unitSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.unitWidth, alignment: .leading)
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}
