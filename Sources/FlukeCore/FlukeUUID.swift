import Foundation

/// The Fluke Connect BLE profile. Every vendor UUID shares one base with a 16-bit slot in the
/// first group: `B698xxxx-7562-11E2-B50D-00163E46F8FE`.
///
/// Sources (all third-party, none from Fluke): the community `fluke-connect-client` crate and
/// `open289` (both tested against an IR3000 FC adapter on a Fluke 289) and the `mutekh` BLE
/// profile (a different Fluke module family). All three agree on the service and on `290F`, the
/// binary live-reading characteristic. Nobody has published a capture from a 1587 FC.
public enum FlukeUUID {
    public static let base = "-7562-11E2-B50D-00163E46F8FE"

    /// The reading service, advertised by Fluke Connect devices.
    public static let readingService = vendor("B6981800")
    /// Binary live reading: 8 bytes per notification (16 on the IR3000 FC: primary + secondary).
    public static let binaryReading = vendor("B698290F")
    /// ASCII display (17 bytes). Populated on some clamp meters, a placeholder on others.
    public static let asciiReading = vendor("B6982901")
    /// Connection ID (one byte, read/write, resets to 0 on disconnect). A client writes its number here
    /// and the meter shows it as "ID#" on its display, as Fluke's own app does. A meter that never gets
    /// one appears to treat the connection as unidentified and drops it after a while.
    public static let connectionID = vendor("B6982902")

    // Standard Bluetooth SIG characteristics (Device Information service).
    public static let modelNumber = "2A24"
    public static let serialNumber = "2A25"
    public static let firmwareRevision = "2A26"
    public static let softwareRevision = "2A28"
    public static let manufacturerName = "2A29"
    public static let deviceName = "2A00"

    /// Undocumented characteristics on the 1587 FC that look like meter state (one reads back the text
    /// "Read"). Only watched (subscribed or read, never written to): the app logs each change so button presses (HOLD, MIN MAX…)
    /// can be matched to what changes. Notify-only ones are subscribed to; the rest are polled.
    public static let watchedNotify = [vendor("B6982906"), vendor("B6982908"), vendor("B6982909"), vendor("B698290E"), vendor("B6982917")]
    public static let watchedPolled = [vendor("B6982906"), vendor("B6982907"), vendor("B6982908"), vendor("B6982909"), vendor("B698290C"), vendor("B698290D")]
    public static var watched: Set<String> { Set(watchedNotify + watchedPolled) }

    /// Characteristics that update firmware. The app writes to exactly one characteristic (the connection
    /// ID) and never touches these; they're named here so the diagnostics log can flag them.
    public static let firmwareUpdateWarning: Set<String> = [
        vendor("B6982911"), vendor("B6982912"), vendor("B6982913"), vendor("B6982914"),
    ]

    private static func vendor(_ prefix: String) -> String { prefix + base }
}
