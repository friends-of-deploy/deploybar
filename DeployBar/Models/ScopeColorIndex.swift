import Foundation

/// Picks the default palette slot for a scope. Lives apart from `ScopeColor`
/// (which is SwiftUI) so stores can resolve an index without importing UI.
enum ScopeColorIndex {
    /// How many slots `ScopeColor.palette` holds. Kept in sync by
    /// `ScopeColorTests`, which fails if the palette grows without this.
    static let paletteCount = 8

    /// Assigns each scope a palette slot by its position in the sorted id list.
    ///
    /// Deliberately NOT a hash of the id. Hashing looks appealing — every scope
    /// resolves independently — but with 8 slots it collides constantly: about
    /// 81% of users with 5 scopes would see at least two sources sharing a
    /// color, which is precisely when telling them apart matters. Assigning by
    /// position guarantees distinct colors while there are slots to go around.
    ///
    /// Sorting by id (not by display name) keeps a scope's color stable when a
    /// team is renamed; only adding or removing a scope can shift things.
    static func assignments(scopeIds: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (offset, id) in scopeIds.sorted().enumerated() {
            result[id] = offset % paletteCount
        }
        return result
    }

    /// Slot for one scope among a known set. Falls back to a stable per-id hash
    /// when the scope isn't in the list (a row whose source was just removed),
    /// so it still gets *some* consistent color rather than defaulting to slot 0.
    static func index(for scopeId: String, among scopeIds: [String]) -> Int {
        if let assigned = assignments(scopeIds: scopeIds)[scopeId] { return assigned }
        return fallbackIndex(scopeId: scopeId)
    }

    /// Stable slot derived from the id alone.
    ///
    /// Uses FNV-1a rather than `hashValue`: Swift's string hashing is seeded per
    /// process, so the same scope would change color on every launch.
    static func fallbackIndex(scopeId: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in scopeId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(paletteCount))
    }
}
