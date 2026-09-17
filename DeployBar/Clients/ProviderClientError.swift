import Foundation

/// Error surface shared by every provider client (Vercel, GitHub, …). The
/// aggregator branches on `.unauthorized` for token-refresh / logout handling
/// regardless of which provider raised it.
enum ProviderClientError: Error, Equatable {
    case unauthorized
    /// The provider is throttling us. Distinct from `.unauthorized` because the
    /// token is fine and must NOT be counted toward the logout threshold:
    /// GitHub reports an exhausted rate limit as 403 (not 429), which would
    /// otherwise read as three failed auths and tell the user to reconnect a
    /// perfectly valid token. `retryAfter` is the server's hint, when it sends one.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
}

extension HTTPURLResponse {
    /// True when this response is a throttle rather than an auth failure.
    ///
    /// 429 is unambiguous. GitHub instead returns 403 with the remaining-quota
    /// header at zero (primary limit) or a `retry-after` (secondary limit).
    var isRateLimited: Bool {
        if statusCode == 429 { return true }
        guard statusCode == 403 else { return false }
        if value(forHTTPHeaderField: "retry-after") != nil { return true }
        return value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
    }

    /// Seconds to wait, from `Retry-After` (delta form) or the reset timestamp.
    var retryAfterSeconds: TimeInterval? {
        if let raw = value(forHTTPHeaderField: "retry-after"), let secs = TimeInterval(raw) {
            return secs
        }
        if let raw = value(forHTTPHeaderField: "x-ratelimit-reset"), let epoch = TimeInterval(raw) {
            return max(0, epoch - Date().timeIntervalSince1970)
        }
        return nil
    }
}
