import Foundation
import AppKit

actor FaviconCache {
    static let shared = FaviconCache()

    private let memory = NSCache<NSString, NSImage>()
    private let dir: URL
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("DeployBar/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func image(for host: String?) async -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        let key = host as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let safe = host.replacingOccurrences(of: "/", with: "_")
        let fileURL = dir.appendingPathComponent("\(safe).png")
        if let data = try? Data(contentsOf: fileURL), let img = NSImage(data: data) {
            memory.setObject(img, forKey: key)
            return img
        }

        // Try sources in order of fidelity: the site's own favicon first
        // (real brand icon), then Google's favicon service as a fallback.
        for url in FaviconURL.candidates(forHost: host) {
            if let img = await fetchImage(url) {
                // Re-encode to PNG so the on-disk cache is always a decodable image.
                if let png = img.pngData() { try? png.write(to: fileURL) }
                memory.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }

    /// Fetches and validates that the response is actually a usable image
    /// (rejects HTML 404/401 bodies that happen to return 200-ish or non-2xx).
    private func fetchImage(_ url: URL) async -> NSImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            // Reject HTML error pages masquerading as a favicon.
            if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               type.contains("text/html") { return nil }
            guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
            return img
        } catch {
            return nil
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
