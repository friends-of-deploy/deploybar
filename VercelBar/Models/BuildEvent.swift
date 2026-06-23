import Foundation

/// A single line of build output from Vercel's deployment events endpoint
/// (`/v3/deployments/{id}/events`). The endpoint returns a flat JSON array where
/// each element carries `text` (the log line) and `level` ("error"/"info") at the
/// top level — there is no nested `payload`.
struct BuildEvent: Decodable {
    let type: String          // "stdout" or "stderr"
    let text: String?
    let level: String?        // "error", "warning", "info" — nil when absent
    let createdMs: Double?

    enum CodingKeys: String, CodingKey { case type, text, level, created }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        text = try c.decodeIfPresent(String.self, forKey: .text)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        createdMs = try c.decodeIfPresent(Double.self, forKey: .created)
    }

    /// Memberwise init for tests.
    init(type: String, text: String?, level: String? = nil, createdMs: Double? = nil) {
        self.type = type
        self.text = text
        self.level = level
        self.createdMs = createdMs
    }
}

/// Builds the clipboard text for a failed deployment: a context header plus the
/// tail of the build log, biased toward the error output. Pure so it's testable.
enum BuildErrorReport {
    /// How many trailing log lines to include. The failure is almost always at
    /// the end of the log; this keeps the paste focused without dumping the
    /// entire build.
    static let tailLineCount = 60

    static func make(for deployment: Deployment, events: [BuildEvent]) -> String {
        var lines: [String] = []
        lines.append("Vercel deployment failed")
        lines.append("Project: \(deployment.name)")
        if let ref = deployment.commitRef { lines.append("Branch: \(ref)") }
        if let msg = deployment.commitMessage?.split(separator: "\n", maxSplits: 1).first {
            lines.append("Commit: \(msg)")
        }
        if let inspector = deployment.inspectorUrl { lines.append("Logs: \(inspector)") }
        lines.append("")
        lines.append("--- Build log (tail) ---")
        lines.append(logTail(from: events))
        return lines.joined(separator: "\n")
    }

    /// The trailing `tailLineCount` lines of stdout/stderr output, in order.
    static func logTail(from events: [BuildEvent]) -> String {
        let logLines = events
            .filter { $0.type == "stdout" || $0.type == "stderr" }
            .compactMap { $0.text }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let tail = logLines.suffix(tailLineCount)
        let text = tail.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no build output captured)" : text
    }
}
