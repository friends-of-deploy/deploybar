import SwiftUI

/// Small colored marker identifying which account/team a row came from.
///
/// Shown only in the "All sources" view, where one list mixes scopes and two
/// teams can hold projects with the same name. A dot rather than a text chip:
/// in a 380pt popover the label competed with the project name and commit
/// message for the row's scarcest resource, horizontal space. The color is a
/// recognition aid for a handful of scopes you see every day; the tooltip
/// carries the actual name for when recognition fails.
struct ScopeDot: View {
    let label: String

    var body: some View {
        Circle()
            .fill(ScopeDot.color(for: label))
            .frame(width: 6, height: 6)
            .tooltip(label)
            .accessibilityLabel(Text("Source: \(label)"))
    }

    /// Deterministic hue for a scope name, so a given team keeps the same color
    /// across launches without anyone configuring one.
    ///
    /// Uses FNV-1a rather than `hashValue`: Swift's string hashing is seeded per
    /// process, which would repaint every dot on each launch.
    static func color(for label: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Golden-angle spacing keeps neighboring hashes visually distinct.
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}
