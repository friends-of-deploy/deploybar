import Foundation

/// Builds the clipboard text for a failed GitHub Actions run: a context header,
/// the failed jobs and steps, and the tail of the failing job's log. Pure so it's
/// testable. Mirrors `BuildErrorReport` (the Vercel equivalent).
enum GitHubActionsErrorReport {
    /// Trailing log lines to include — the failure is almost always at the end.
    static let tailLineCount = 60

    static func make(deployment: Deployment, failedJobs: [GHJob], logTail: String?) -> String {
        var lines: [String] = []
        lines.append("GitHub Actions run failed")
        lines.append("Repository: \(deployment.name)")
        if let ref = deployment.commitRef { lines.append("Branch: \(ref)") }
        if let msg = deployment.commitMessage?.split(separator: "\n", maxSplits: 1).first {
            lines.append("Run: \(msg)")
        }
        if let url = deployment.webURL?.absoluteString { lines.append("Logs: \(url)") }

        if failedJobs.isEmpty {
            lines.append("")
            lines.append("(no failed jobs reported)")
        } else {
            for job in failedJobs {
                lines.append("")
                lines.append("Failed job: \(job.name)")
                for step in (job.steps ?? []) where isFailure(step.conclusion) {
                    lines.append("  ✗ \(step.name)")
                }
            }
        }

        if let tail = logTail.flatMap(nonEmptyTail) {
            lines.append("")
            lines.append("--- Job log (tail) ---")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }

    /// The trailing `tailLineCount` lines of a raw log, trimmed; nil when empty.
    static func nonEmptyTail(_ raw: String) -> String? {
        let logLines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let text = logLines.suffix(tailLineCount)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// GitHub run/job/step conclusions that count as a failure.
    static func isFailure(_ conclusion: String?) -> Bool {
        switch conclusion {
        case "failure", "timed_out", "startup_failure": return true
        default:                                        return false
        }
    }
}
