import SwiftUI

struct FaviconView: View {
    let host: String?
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
        .task(id: host) {
            image = await FaviconCache.shared.image(for: host)
        }
    }
}
