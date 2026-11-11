import SwiftUI

extension Color {
    /// A nod to the meters' yellow holsters.
    static let fluke = Color(red: 1.0, green: 0.78, blue: 0.0)
}

enum Format {
    /// A value scaled to an SI prefix with about four significant digits: "52.00 µV", "5.065 V", "1.234 GΩ".
    static func si(_ value: Double, unit: String) -> String {
        guard value != 0 else { return "0 \(unit)" }
        let magnitude = abs(value)
        let order = Int(floor(log10(magnitude)))
        let exp3 = min(max(Int(floor(Double(order) / 3.0)) * 3, -12), 12)
        let scaled = value / pow(10.0, Double(exp3))
        let decimals = max(0, 3 - (order - exp3))
        return String(format: "%.\(decimals)f", scaled) + " " + prefix(exp3) + unit
    }

    /// Axis tick labels: "5M", "1.5µ".
    static func axis(_ value: Double) -> String {
        guard value != 0 else { return "0" }
        let magnitude = abs(value)
        let order = Int(floor(log10(magnitude)))
        let exp3 = min(max(Int(floor(Double(order) / 3.0)) * 3, -12), 12)
        let scaled = magnitude / pow(10.0, Double(exp3))
        let rounded = (scaled * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return (value < 0 ? "-" : "") + number + prefix(exp3)
    }

    private static func prefix(_ exponent: Int) -> String {
        switch exponent {
        case -12: "p"
        case -9: "n"
        case -6: "µ"
        case -3: "m"
        case 3: "k"
        case 6: "M"
        case 9: "G"
        case 12: "T"
        default: ""
        }
    }
}

// MARK: - Glass

private struct GlassEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False only for the dev-only off-screen preview, where `.glassEffect` draws nothing at all.
    var glassEnabled: Bool {
        get { self[GlassEnabledKey.self] }
        set { self[GlassEnabledKey.self] = newValue }
    }
}

private struct GlassCardModifier<S: Shape>: ViewModifier {
    @Environment(\.glassEnabled) private var enabled
    let glass: Glass
    let shape: S

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(glass, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass surface (the same as `glassEffect`, but previewable off-screen).
    func glassCard<S: Shape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(GlassCardModifier(glass: glass, shape: shape))
    }
}
