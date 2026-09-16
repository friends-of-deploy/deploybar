import SwiftUI

/// The color identifying a scope (account, or account + Vercel team) wherever a
/// row needs to say where it came from.
///
/// Every scope gets a usable color with no configuration: one is derived from
/// the scope's stable id. The user can override any of them in
/// Settings › Accounts when two scopes land on colors that read alike.
enum ScopeColor {
    /// Hand-picked, evenly spaced hues that stay distinguishable against both
    /// the light and dark popover background. Deliberately a fixed list rather
    /// than a continuous hue ramp: arbitrary hues drift into muddy olives and
    /// near-greys that read as "disabled" next to the status dots.
    static let palette: [Color] = [
        Color(hue: 0.58, saturation: 0.62, brightness: 0.92),  // azure
        Color(hue: 0.78, saturation: 0.52, brightness: 0.90),  // violet
        Color(hue: 0.92, saturation: 0.55, brightness: 0.92),  // pink
        Color(hue: 0.05, saturation: 0.65, brightness: 0.95),  // coral
        Color(hue: 0.12, saturation: 0.70, brightness: 0.92),  // amber
        Color(hue: 0.35, saturation: 0.55, brightness: 0.80),  // moss
        Color(hue: 0.47, saturation: 0.58, brightness: 0.82),  // teal
        Color(hue: 0.68, saturation: 0.50, brightness: 0.92),  // periwinkle
    ]

    static let names: [String] = [
        "Azure", "Violet", "Pink", "Coral", "Amber", "Moss", "Teal", "Periwinkle",
    ]

    /// Safe lookup — an override persisted before a palette change can point
    /// past the end of the list.
    static func color(at index: Int) -> Color {
        palette.indices.contains(index) ? palette[index] : palette[0]
    }
}
