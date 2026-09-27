import Foundation

/// The account-wide `/user/repos` listing, fetched once per poll tick and
/// shared by every organization scope of the account.
///
/// Organization scopes all read the same authenticated listing and keep only
/// their owner's repositories, so without sharing each one listed it again —
/// twice, for projects and for deployments. Concurrent callers join the one
/// in-flight fetch. A failed fetch is not kept, so the next caller fetches
/// again, unless GitHub was throttling: a rate-limited listing stays until
/// `reset()`, so every later organization of the tick gets the same error
/// without spending another request against an exhausted limit.
actor GitHubRepositoryListing {
    private var entries: [String: Task<[GHRepo], Error>] = [:]

    /// The listing for `token`, fetched with `load` on first use this tick.
    /// Keyed by token, so a rotated token never sees the old one's listing.
    func repositories(token: String,
                      load: @escaping @Sendable () async throws -> [GHRepo]) async throws -> [GHRepo] {
        if let entry = entries[token] { return try await entry.value }
        let entry = Task { try await load() }
        entries[token] = entry
        do {
            return try await entry.value
        } catch {
            // A throttle stays until `reset()`. Anything else is dropped, unless
            // a reset and a newer fetch have replaced it meanwhile.
            let throttled = if case ProviderClientError.rateLimited = error { true } else { false }
            if !throttled, entries[token] == entry { entries[token] = nil }
            throw error
        }
    }

    /// Starts a new tick: the next caller fetches a fresh listing.
    func reset() {
        entries.removeAll()
    }
}
