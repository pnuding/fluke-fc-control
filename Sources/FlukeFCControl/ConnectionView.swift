import SwiftUI

/// The connection dialog: the meters this Mac knows (each with its ID#, serial number and firmware), and
/// the Fluke devices in range that can be added. Shown as a popover from a meter window's Bluetooth button,
/// and as the content of a window that has no meter yet.
struct ConnectionView: View {
    /// Makes sure this meter has a window (the caller opens one, or reuses the empty window it lives in).
    let open: (FlukeMeter) -> Void
    @Environment(FlukeHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        VStack(alignment: .leading, spacing: 20) {
            if let message = unavailableMessage {
                BluetoothUnavailableView(message: message, canOpenSettings: hub.radio == .unauthorized)
            } else {
                if !hub.meters.isEmpty {
                    section("Your Meters") {
                        ForEach(hub.meters) { meter in ownedRow(meter) }
                    }
                }
                section(hub.meters.isEmpty ? "Choose a meter" : "Nearby") {
                    nearbySection
                }
                otherDevices(show: $hub.showOtherDevices)
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hub.beginScanning() }
        .onDisappear { hub.endScanning() }
    }

    private var unavailableMessage: String? {
        switch hub.radio {
        case .poweredOff: String(localized: "Bluetooth is turned off.")
        case .unauthorized: String(localized: "Bluetooth access is denied. Allow it for this app in System Settings → Privacy & Security → Bluetooth.")
        case .unsupported: String(localized: "This Mac doesn't support Bluetooth Low Energy.")
        default: nil
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    // MARK: Meters you have

    private func ownedRow(_ meter: FlukeMeter) -> some View {
        let isConnected = meter.enabled && meter.link != .idle
        return HStack(spacing: 12) {
            Image(systemName: statusSymbol(meter))
                .foregroundStyle(statusColor(meter))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(meter.name).font(.headline).lineLimit(1)
                Text(verbatim: "\(statusText(meter)) · ID# \(meter.connectionID)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let detail = detailText(meter) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isConnected {
                Button("Open") { open(meter) }
                    .buttonStyle(.glass)
                    .help("Show this meter's window")
            } else {
                Button("Connect") { open(meter) }
                    .buttonStyle(.glassProminent)
            }
            Menu {
                if isConnected {
                    Button("Disconnect") { hub.disconnect(meter) }
                }
                Button("Reconnect") {
                    hub.reconnect(meter)
                    open(meter)
                }
                Button("Forget Meter", role: .destructive) { hub.forget(meter) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    /// "S/N 1567380832 · FW V02.06.00". Both are remembered, so they show for meters that aren't connected
    /// right now. `nil` until a meter has been connected once.
    private func detailText(_ meter: FlukeMeter) -> String? {
        var parts: [String] = []
        if let serial = meter.info.serial { parts.append(String(localized: "S/N \(serial)")) }
        if let firmware = meter.firmwareText { parts.append(String(localized: "FW \(firmware)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func statusText(_ meter: FlukeMeter) -> String {
        guard meter.enabled else { return String(localized: "Not connected") }
        return switch meter.link {
        case .idle: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting…")
        case .connected: meter.lastReadingAt == nil ? String(localized: "Connected · waiting for readings") : String(localized: "Connected")
        case .retrying(let reason): String(localized: "Reconnecting… \(reason)")
        case .bluetoothUnavailable(let message): message
        }
    }

    private func statusSymbol(_ meter: FlukeMeter) -> String {
        guard meter.enabled else { return "circle" }
        return switch meter.link {
        case .connected: "checkmark.circle.fill"
        case .bluetoothUnavailable: "exclamationmark.triangle.fill"
        case .idle: "circle"
        case .connecting, .retrying: "circle.dotted"
        }
    }

    private func statusColor(_ meter: FlukeMeter) -> Color {
        guard meter.enabled else { return .secondary }
        return switch meter.link {
        case .connected: .green
        case .bluetoothUnavailable, .retrying: .orange
        case .idle, .connecting: .secondary
        }
    }

    // MARK: In range

    @ViewBuilder
    private var nearbySection: some View {
        if hub.nearbyLikely.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(hub.meters.isEmpty ? String(localized: "Looking for meters…") : String(localized: "Looking for more meters…"))
                        .foregroundStyle(.secondary)
                }
                Text("Turn Bluetooth on at the meter and keep it close to this Mac. A meter only talks to one app at a time, so close Fluke Connect on your phone first. Fluke devices advertise slowly, so this can take up to 10 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ForEach(hub.nearbyLikely) { device in
                nearbyRow(device, caption: device.advertisesService
                    ? String(localized: "Fluke Connect device")
                    : String(localized: "Might be a Fluke meter"))
            }
        }
    }

    private func otherDevices(show: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: show) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Only try this if your meter isn't listed above. If the device turns out not to be a Fluke Connect meter, the connection fails with an explanation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hub.nearbyOthers.isEmpty {
                    Text("No other named Bluetooth devices in range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // A busy room has dozens of named Bluetooth devices. The list scrolls inside a fixed
                    // height instead of growing the dialog off the screen, which would bury the controls.
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(hub.nearbyOthers) { device in
                                nearbyRow(device, caption: String(localized: "Unknown device"))
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Other Bluetooth devices").font(.subheadline)
        }
    }

    private func nearbyRow(_ device: DiscoveredMeter, caption: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cellularbars", variableValue: min(max(Double(device.rssi + 95) / 50, 0.05), 1))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.headline).lineLimit(1)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.isLikely {
                Button("Add") { open(hub.add(device)) }
                    .buttonStyle(.glassProminent)
            } else {
                Button("Add") { open(hub.add(device)) }
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
    }
}

struct BluetoothUnavailableView: View {
    let message: String
    var canOpenSettings = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Bluetooth Unavailable").font(.title3.bold())
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if canOpenSettings {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }
                .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
