import Foundation

/// The "ID#" a client writes to a meter's connection-ID characteristic (one byte; the meter shows it on its
/// display). With several meters, each gets its own, so you can tell them apart on the bench.
public enum ConnectionID {
    public static let range = 1...255

    /// The lowest number in 1...255 that isn't in `used`; `nil` if all 255 are taken.
    public static func next<S: Sequence>(avoiding used: S) -> Int? where S.Element == Int {
        let taken = Set(used)
        return range.first { !taken.contains($0) }
    }
}
