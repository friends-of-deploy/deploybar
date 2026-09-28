import Foundation

/// Where the snapshot lives: a single JSON file in the App Group container both
/// the app and the widget extension are entitled to.
enum WidgetSnapshotFile {
    /// Team-ID-prefixed (macOS form): a Developer ID app may claim it without a
    /// provisioning profile. Must match both entitlements files.
    static let appGroupID = "7S3F9767BM.io.eightlines.deploybar"
    static let fileName = "widget-snapshot.json"

    static var defaultURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    static func read(from url: URL? = defaultURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return WidgetSnapshot.decode(data)
    }

    /// Atomic, so the widget never reads a half-written file.
    static func write(_ snapshot: WidgetSnapshot, to url: URL? = defaultURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try snapshot.encoded().write(to: url, options: .atomic)
    }
}
