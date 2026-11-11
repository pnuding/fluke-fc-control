import AppKit
import SwiftUI

/// One hub for the whole process; the delegate needs it before any scene exists.
@MainActor let sharedHub = FlukeHub()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { sharedHub.start() }
    }

    /// Closing the last window quits. (Not during a `--probe` run, which has a report to write and shouldn't
    /// be cut short by someone closing its window.)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !sharedHub.isProbe }
    }

    /// Windows closing on the way out must not count as "the user disconnected this meter".
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { sharedHub.isQuitting = true }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { sharedHub.shutdown() }
    }
}

@main
struct FlukeFCControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window per meter. Several can be merged into one tabbed window (Window → Merge All Windows).
        // Not a value-based group: SwiftUI opens one of those at launch, which is what lets this app start
        // with its meters' windows without any helper. Each window works out its meter itself (see MeterWindow).
        WindowGroup("Fluke FC Control", id: "meter") {
            MeterWindow()
                .environment(sharedHub)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        // A real separate window per meter (not a popover) so it can stay open alongside the meter's own.
        WindowGroup("Graph", id: "graph", for: UUID.self) { $id in
            GraphWindow(id: id)
                .environment(sharedHub)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Diagnostics", id: "diagnostics", for: UUID.self) { $id in
            DiagnosticsWindow(id: id)
                .environment(sharedHub)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { AppCommands() }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The meter whose window is in front.
    @FocusedValue(\.meterID) private var meterID

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Diagnostics…") {
                guard let meterID else { return }
                openWindow(id: "diagnostics", value: meterID)
                NSApp.activate()
            }
            .disabled(meterID == nil)
        }
    }
}
