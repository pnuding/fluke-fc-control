import FlukeCore
import SwiftUI

/// The window of one meter: its readout card, a connection button (the meter list) and a graph button.
struct MeterContentView: View {
    let meter: FlukeMeter
    @Environment(FlukeHub.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @State private var showConnection = false

    var body: some View {
        MeasurementCardView(meter: meter)
            .padding(16)
            // .fixedSize() makes this view report its natural size as min/ideal/max at once; with
            // .windowResizability(.contentSize) on the scene the window is exactly as big as its content
            // needs, so nothing is ever clipped and there's no hardcoded width to maintain.
            .fixedSize()
            // The name, then the ID# the meter shows on its own display.
            .navigationTitle(meter.title)
            .focusedSceneValue(\.meterID, meter.id)
            .background(WindowTracker(
                onAttach: { window in hub.meterWindowOpened(meter.id, window: window) },
                onClose: { window in hub.meterWindowClosed(meter.id, window: window) }
            ))
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    connectionButton
                    Button {
                        openWindow(id: "graph", value: meter.id)
                    } label: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    .help("Open graph window")
                    .accessibilityLabel("Open graph window")
                }
            }
    }

    // MARK: Connection button

    private var connectionButton: some View {
        let (symbol, color, label) = connectionAppearance
        return Button {
            showConnection.toggle()
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .popover(isPresented: $showConnection) {
            ConnectionView(open: { other in
                hub.connect(other)
                hub.showWindow(for: other, openWindow: openWindow)
            })
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(Text("Your meters and meters nearby"))
    }

    private var connectionAppearance: (String, Color, LocalizedStringKey) {
        switch meter.link {
        case .connected: ("dot.radiowaves.left.and.right", .green, "Connected")
        case .connecting: ("dot.radiowaves.left.and.right", .secondary, "Connecting…")
        case .retrying: ("dot.radiowaves.left.and.right", .orange, "Reconnecting…")
        case .bluetoothUnavailable: ("antenna.radiowaves.left.and.right.slash", .orange, "Bluetooth unavailable")
        case .idle: ("antenna.radiowaves.left.and.right.slash", .secondary, "Not connected")
        }
    }
}
