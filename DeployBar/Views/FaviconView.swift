import SwiftUI

struct FaviconView: View {
    let host: String?
    /// Fallback direct image URL (e.g. a GitHub owner avatar) when there is no
    /// production domain to derive a favicon from.
    var directURL: String? = nil
    @State private var image: NSImage?

    var body: some View {
        // Keep both layers alive throughout the row's tab transition. Inserting
        // a new Image after the first load gives it a different animation path
        // from an image that was already loaded when the transition started.
        ZStack {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .padding(3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .opacity(image == nil ? 1 : 0)
            // This expression always produces one Image, without a conditional
            // view branch that would replace it while the row is moving.
            (image.map { Image(nsImage: $0) } ?? Image(systemName: "globe"))
                .resizable()
                .interpolation(.high)
                .opacity(image == nil ? 0 : 1)
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: host ?? directURL) {
            image = await FaviconCache.shared.image(for: host, directURL: directURL)
        }
    }
}
