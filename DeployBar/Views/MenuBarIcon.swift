import SwiftUI

/// Menu bar icon: the ▲ glyph with a small colored status dot in the top-trailing corner.
struct MenuBarIcon: View {
    let state: IconState

    private var dotColor: Color {
        switch state {
        case .ready:     return .green
        case .building:  return .orange
        case .failure:   return .red
        case .loggedOut: return .gray
        }
    }

    var body: some View {
        Image(systemName: "triangle.fill")
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
            }
    }
}
