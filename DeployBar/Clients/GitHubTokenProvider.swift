import Foundation

/// Reads the GitHub CLI (`gh`) OAuth token so DeployBar can reuse an existing
/// `gh auth login` session, mirroring how `TokenProvider` reuses the Vercel CLI.
///
/// On macOS `gh` stores its token in the system keyring (not a readable plaintext
/// file), so the reliable way to obtain it is to invoke `gh auth token`. GUI apps
/// don't inherit the shell `PATH`, so we probe the common Homebrew / standard
/// install locations for the binary rather than relying on `PATH`.
struct GitHubTokenProvider {
    /// Candidate `gh` binary locations (a GUI app's PATH is minimal, so probe explicitly).
    static let defaultBinaryCandidates = [
        "/opt/homebrew/bin/gh",   // Apple-silicon Homebrew
        "/usr/local/bin/gh",      // Intel Homebrew
        "/usr/bin/gh",
        "/opt/local/bin/gh",      // MacPorts
    ]

    let binaryCandidates: [String]
    /// Runs a command and returns trimmed stdout, or nil on failure / non-zero exit.
    /// Injectable so tests exercise the logic without a real `gh` install.
    let run: (_ launchPath: String, _ arguments: [String]) -> String?

    init(binaryCandidates: [String] = GitHubTokenProvider.defaultBinaryCandidates,
         run: @escaping (String, [String]) -> String? = GitHubTokenProvider.shell) {
        self.binaryCandidates = binaryCandidates
        self.run = run
    }

    /// The current `gh` token for github.com, or nil when not logged in / `gh` absent.
    func token() -> String? {
        guard let gh = binaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        guard let out = run(gh, ["auth", "token", "--hostname", "github.com"]),
              !out.isEmpty else { return nil }
        return out
    }

    /// Default runner using `Process`. Returns trimmed stdout on a clean (exit 0) run.
    static func shell(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
