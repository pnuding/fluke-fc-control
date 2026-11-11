import AppKit
import SwiftUI

// MARK: - The meter window

/// One window per meter, openable side by side or merged into tabs with Window → Merge All Windows. Every
/// new window starts with no meter and takes the one it was opened for (see `FlukeHub.takePendingWindow`);
/// a window nobody asked for (File → New Window, or the first launch with nothing saved) shows the meter
/// picker and becomes a meter window once you choose one.
struct MeterWindow: View {
    @State private var id: UUID?
    @Environment(FlukeHub.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let id {
                if let meter = hub.meter(id: id) {
                    MeterContentView(meter: meter)
                } else {
                    // The meter was forgotten while its window was open.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .task { dismiss() }
                }
            } else {
                PickerWindowContent(id: $id)
            }
        }
        .task { claimMeter() }
    }

    /// Takes the meter this window was opened for. At launch, the first window takes the first saved meter
    /// and opens a window for each of the others; windows created later find the launch list empty.
    private func claimMeter() {
        guard id == nil else { return }
        if let requested = hub.takePendingWindow() {
            id = requested
            return
        }
        let queue = hub.takeLaunchQueue()
        guard let first = queue.first else { return }
        id = first
        for other in queue.dropFirst() {
            hub.requestWindow(for: other)
            openWindow(id: "meter")
        }
    }
}

/// The "choose a meter" content of a window that has none yet.
private struct PickerWindowContent: View {
    @Binding var id: UUID?
    @Environment(FlukeHub.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ConnectionView(open: { meter in
            hub.connect(meter)
            // A meter already shown in another window is brought forward instead of opened twice.
            if hub.isWindowOpen(meter.id) { hub.showWindow(for: meter, openWindow: openWindow) } else { id = meter.id }
        })
        .navigationTitle("Fluke FC Control")
        .onChange(of: hub.autoOpenRequests) { _, requests in
            guard id == nil, let first = requests.first else { return }
            hub.autoOpenRequests.removeAll()
            id = first
        }
    }
}

// MARK: - Per-meter graph and diagnostics windows

struct GraphWindow: View {
    let id: UUID?
    @Environment(FlukeHub.self) private var hub

    var body: some View {
        if let id, let meter = hub.meter(id: id) {
            GraphView(meter: meter)
                .padding()
                .frame(minWidth: 480, minHeight: 480)
                .navigationTitle("Graph · \(meter.title)")
        } else {
            Text("This meter is no longer in the list.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}

struct DiagnosticsWindow: View {
    let id: UUID?
    @Environment(FlukeHub.self) private var hub

    var body: some View {
        if let id, let meter = hub.meter(id: id) {
            DiagnosticsView(meter: meter)
                .padding()
                .frame(minWidth: 560, minHeight: 360)
                .navigationTitle("Diagnostics · \(meter.title)")
        } else {
            Text("This meter is no longer in the list.")
                .foregroundStyle(.secondary)
                .padding(40)
        }
    }
}

// MARK: - Which meter is frontmost (for the Diagnostics… menu command)

struct FocusedMeterKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var meterID: UUID? {
        get { self[FocusedMeterKey.self] }
        set { self[FocusedMeterKey.self] = newValue }
    }
}

// MARK: - Knowing when a window really closes

/// Reports when its window appears and when it actually closes. SwiftUI's onDisappear isn't used for this
/// because it can also fire when a tab is merely sent to the background, which must not disconnect a meter.
struct WindowTracker: NSViewRepresentable {
    var onAttach: @MainActor (NSWindow) -> Void
    var onClose: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> TrackerView {
        TrackerView(onAttach: onAttach, onClose: onClose)
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onAttach = onAttach
        view.onClose = onClose
    }

    final class TrackerView: NSView {
        var onAttach: @MainActor (NSWindow) -> Void
        var onClose: @MainActor (NSWindow) -> Void
        private nonisolated(unsafe) var observer: NSObjectProtocol?

        init(onAttach: @escaping @MainActor (NSWindow) -> Void, onClose: @escaping @MainActor (NSWindow) -> Void) {
            self.onAttach = onAttach
            self.onClose = onClose
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            onAttach(window)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] note in
                guard let closing = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.onClose(closing) }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
