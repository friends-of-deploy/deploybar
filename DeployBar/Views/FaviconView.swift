import SwiftUI

struct FaviconView: View {
    let host: String?
    /// Fallback direct image URL (e.g. a GitHub owner avatar) when there is no
    /// production domain to derive a favicon from.
    var directURL: String? = nil
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: host ?? directURL) {
            image = await FaviconCache.shared.image(for: host, directURL: directURL)
        }
    }
}
