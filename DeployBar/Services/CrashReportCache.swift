import Foundation

/// An old SDK queue may finish a disk write after close(). A new consent grant
/// must never reuse that queue's directory, even if the root was just deleted.
struct CrashReportCache {
    struct Grant: Codable {
        let id: UUID
        let startedAt: Date
    }

    let directory: URL

    func prepare() throws -> Grant {
        let marker = directory.appendingPathComponent("consent.json")
        if FileManager.default.fileExists(atPath: marker.path) {
            // A corrupt marker fails closed instead of reviving orphaned data.
            return try JSONDecoder().decode(Grant.self, from: Data(contentsOf: marker))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grant = Grant(id: UUID(), startedAt: Date())
        try JSONEncoder().encode(grant).write(to: marker, options: .atomic)
        return grant
    }

    func directory(for grant: Grant) -> URL {
        directory.appendingPathComponent(grant.id.uuidString, isDirectory: true)
    }

    func discard() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
