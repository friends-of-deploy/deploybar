import Foundation

/// Clipboard text for a failed Azure DevOps run: a context header, the failed
/// tasks with their error messages, and the tail of the first failed task's
/// log. Pure so it's testable; mirrors `GitHubActionsErrorReport`.
enum AzureDevOpsErrorReport {
    static func make(deployment: Deployment, failedTasks: [ADOTimelineRecord], logTail: String?) -> String {
        var lines: [String] = []
        lines.append("Azure DevOps run failed")
        lines.append("Repository: \(deployment.name)")
        if let ref = deployment.commitRef { lines.append("Branch: \(ref)") }
        if let msg = deployment.commitMessage?.split(separator: "\n", maxSplits: 1).first {
            lines.append("Run: \(msg)")
        }
        if let url = deployment.webURL?.absoluteString { lines.append("Logs: \(url)") }

        if failedTasks.isEmpty {
            lines.append("")
            lines.append("(no failed tasks reported)")
        } else {
            for task in failedTasks {
                lines.append("")
                lines.append("Failed task: \(task.name ?? "unnamed")")
                for issue in task.issues ?? [] where issue.type == "error" {
                    if let message = issue.message { lines.append("  ✗ \(message)") }
                }
            }
        }

        if let tail = logTail.flatMap(GitHubActionsErrorReport.nonEmptyTail) {
            lines.append("")
            lines.append("--- Task log (tail) ---")
            lines.append(tail)
        }
        return lines.joined(separator: "\n")
    }
}
