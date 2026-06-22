import SwiftUI

/// A small, subtle pill used for project metadata (framework, branch, counts).
struct StatChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
