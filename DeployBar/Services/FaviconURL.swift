import Foundation

enum FaviconURL {
    /// Normalizes a bare host ("example.com") or a full URL
    /// ("https://example.com/x") down to just the host.
    static func normalizedHost(_ host: String?) -> String? {
        guard var h = host, !h.isEmpty else { return nil }
        if h.contains("://"), let comps = URLComponents(string: h), let hostPart = comps.host {
            h = hostPart
        } else if let slash = h.firstIndex(of: "/") {
            h = String(h[..<slash])
        }
        return h.isEmpty ? nil : h
    }

    /// The Google favicon-service URL for a host (used as a fallback source).
    static func forHost(_ host: String?) -> URL? {
        guard let h = normalizedHost(host) else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(h)")
    }

    /// Ordered favicon sources to try for a host: the site's own favicon first
    /// (the real brand icon), then Google's favicon service as a fallback.
    static func candidates(forHost host: String?) -> [URL] {
        guard let h = normalizedHost(host) else { return [] }
        return [
            URL(string: "https://\(h)/favicon.ico"),
            URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(h)"),
        ].compactMap { $0 }
    }
}
