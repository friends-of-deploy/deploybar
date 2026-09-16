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
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .tooltip(label)
            .accessibilityLabel(Text("Source: \(label)"))
    }
}
