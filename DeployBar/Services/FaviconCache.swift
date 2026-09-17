import Foundation
import AppKit

/// Memory + disk cache for the small remote images in the popover: project
/// favicons and commit-author avatars.
///
/// Three things matter here beyond "keep the bytes around", and all three are
/// about repeats rather than the first fetch:
///
/// - **Misses are cached too.** Plenty of projects have no favicon at all. Without
///   a remembered miss, every such row re-tried its own domain *and* the Google
///   fallback each time it appeared — and `https://<dead-host>/favicon.ico` does
///   not fail fast, it hangs until the request times out.
/// - **Entries expire.** Sites get rebranded and avatars get changed; a cache with
///   no TTL shows the old one until the user clears `~/Library/Caches` by hand.
/// - **Images are downscaled before storing.** These are drawn at 16pt; one
///   GitHub avatar was landing on disk at 318 KB.
actor FaviconCache {
    static let shared = FaviconCache()

    /// A remembered result. `.miss` is as much a result as an image.
    private enum Entry {
        case hit(NSImage)
        case miss
    }

    private var memory: [String: Entry] = [:]
    private let dir: URL
    private let session: URLSession
    private let ttl: TimeInterval
    private let now: () -> Date

    /// How long a cached image stays good. A day: long enough that the icons are
    /// effectively free during normal use, short enough that a rebrand shows up
    /// without the user doing anything.
    static let defaultTTL: TimeInterval = 24 * 60 * 60

    /// A remembered miss expires much sooner than a hit — a site that has no
    /// favicon today may well get one, and the point is only to stop re-fetching
    /// it on every scroll, not to give up on it for a day.
    static let missTTL: TimeInterval = 30 * 60

    /// Longest edge kept on disk and in memory. The views draw these at 16pt;
    /// 64 leaves room for a Retina 32pt without storing a full-size avatar.
    static let maxPixelSize: CGFloat = 64

    init(session: URLSession = .shared,
         directory: URL? = nil,
         ttl: TimeInterval = FaviconCache.defaultTTL,
         now: @escaping () -> Date = Date.init) {
        self.session = session
        self.ttl = ttl
        self.now = now
        if let directory {
            dir = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            dir = caches.appendingPathComponent("DeployBar/favicons", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Icon for a host's favicon, falling back to a direct image URL (e.g. a
    /// GitHub owner avatar) when no host is available.
    func image(for host: String?, directURL: String? = nil) async -> NSImage? {
        if let host, !host.isEmpty {
            // Try sources in order of fidelity: the site's own favicon first
            // (real brand icon), then Google's favicon service as a fallback.
            return await cachedImage(key: host, candidates: FaviconURL.candidates(forHost: host))
        }
        if let directURL, !directURL.isEmpty, let url = URL(string: directURL) {
            return await cachedImage(key: directURL, candidates: [url])
        }
        return nil
    }

    private func cachedImage(key: String, candidates: [URL]) async -> NSImage? {
        switch memory[key] {
        case .hit(let image): return image
        case .miss:           return nil
        case nil:             break
        }

        if let entry = readFromDisk(key: key) {
            memory[key] = entry
            if case .hit(let image) = entry { return image }
            return nil
        }

        for url in candidates {
            if let image = await fetchImage(url) {
                let stored = image.downscaled(toFit: Self.maxPixelSize)
                writeToDisk(stored, key: key)
                memory[key] = .hit(stored)
                return stored
            }
        }

        // Nothing resolved. Remember that, so the next appearance of this row
        // doesn't repeat the whole candidate walk.
        markMiss(key: key)
        memory[key] = .miss
        return nil
    }

    // MARK: - Disk

    /// A miss is recorded as an empty file: it needs no content, only a name and
    /// a modification date, and that keeps the format the same for both cases.
    private func fileURL(key: String) -> URL {
        let safe = key
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
        return dir.appendingPathComponent("\(safe).png")
    }

    private func readFromDisk(key: String) -> Entry? {
        let url = fileURL(key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date
        else { return nil }

        guard let data = try? Data(contentsOf: url) else { return nil }
        // An empty file is a remembered miss; it expires faster than a hit.
        let age = now().timeIntervalSince(modified)
        guard age < (data.isEmpty ? Self.missTTL : ttl) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard !data.isEmpty else { return .miss }
        guard let image = NSImage(data: data) else { return nil }
        return .hit(image)
    }

    private func writeToDisk(_ image: NSImage, key: String) {
        // Re-encode to PNG so the on-disk cache is always a decodable image.
        guard let png = image.pngData() else { return }
        try? png.write(to: fileURL(key: key))
    }

    private func markMiss(key: String) {
        try? Data().write(to: fileURL(key: key))
    }

    // MARK: - Network

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

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Scales down so the longest edge is at most `limit`, preserving aspect
    /// ratio. Images already within the limit are returned untouched — upscaling
    /// a 16pt favicon would only cost bytes.
    func downscaled(toFit limit: CGFloat) -> NSImage {
        let longest = max(size.width, size.height)
        guard longest > limit, longest > 0 else { return self }
        let scale = limit / longest
        let target = NSSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())
        guard target.width >= 1, target.height >= 1 else { return self }

        let scaled = NSImage(size: target)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        scaled.unlockFocus()
        return scaled
    }
}
