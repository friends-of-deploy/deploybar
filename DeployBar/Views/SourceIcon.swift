import SwiftUI

/// A project/repository icon with its build-status dot badged onto the corner.
///
/// Shared by both lists so a project reads the same whether you are looking at
/// its deployments or the project itself. The dot used to sit in its own column
/// to the icon's left, which spent ~14pt of a 380pt row on a single 8pt dot;
/// overlapping it reclaims that for the row's text.
struct SourceIcon: View {
    let state: DeploymentState
    var host: String?
    var directURL: String?
    var size: CGFloat = 22

    var body: some View {
        FaviconView(host: host, directURL: directURL)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                StatusDot(state: state, size: 8, bordered: true)
                    // Hangs the dot just past the icon's corner so it reads as a
                    // badge on the icon rather than a mark printed inside it.
                    .offset(x: 4, y: -4)
            }
            // Reserve the space the offset dot overhangs into, so the badge
            // never lands under the text column.
            .padding(.trailing, 4)
            .padding(.top, 2)
            .statusTooltip(state)
    }
}
