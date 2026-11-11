import Foundation

/// UserDefaults keys.
enum Pref {
    /// JSON list of the meters this Mac knows: [{id, name}].
    static let meters = "meters"
    /// Superseded by `SavedMeter.enabled`; only read once to migrate older installs.
    static let activeMeter = "activeMeter"
    /// Diagnostics toggle: also subscribe to / poll the 1587 FC's undocumented state characteristics and
    /// log what changes. Off by default (it only adds traffic; it found nothing for HOLD / MIN MAX on the 1587 FC).
    static let watchExtras = "watchExtras"
}

/// A meter remembered across launches. Everything after `name` is optional so older saved lists still load.
struct SavedMeter: Codable, Equatable {
    var id: UUID
    var name: String
    /// The ID# written to this meter (1…255), unique among the saved meters.
    var connectionID: Int?
    /// Whether the meter should connect (and get a window) at launch.
    var enabled: Bool?
    var serial: String?
    var firmware: String?
}
