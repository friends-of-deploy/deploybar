import XCTest
@testable import DeployBar

/// `GitHubTokenProvider` locates a `gh` binary and shells out to `gh auth token`.
/// The `run` closure is injected so these tests never require a real `gh` install;
/// `/bin/sh` stands in as an "existing executable" for the binary-probe path.
final class GitHubCLITokenProviderTests: XCTestCase {

    func test_returnsTrimmedToken() {
        let provider = GitHubTokenProvider(binaryCandidates: ["/bin/sh"]) { path, args in
            XCTAssertEqual(path, "/bin/sh")
            XCTAssertEqual(args, ["auth", "token", "--hostname", "github.com"])
            return "gho_abc123"
        }
        XCTAssertEqual(provider.token(), "gho_abc123")
    }

    func test_nilWhenNoBinaryFound() {
        let provider = GitHubTokenProvider(binaryCandidates: ["/no/such/gh"]) { _, _ in
            XCTFail("run should not be called when no binary exists")
            return "shouldNotHappen"
        }
        XCTAssertNil(provider.token())
    }

    func test_nilWhenCommandProducesNoToken() {
        let provider = GitHubTokenProvider(binaryCandidates: ["/bin/sh"]) { _, _ in nil }
        XCTAssertNil(provider.token())
    }

    func test_nilWhenTokenEmpty() {
        let provider = GitHubTokenProvider(binaryCandidates: ["/bin/sh"]) { _, _ in "" }
        XCTAssertNil(provider.token())
    }

    /// Smoke test of the real `Process` runner against a known binary so the shell
    /// path itself is exercised (independent of whether `gh` is installed).
    func test_shellRunnerCapturesStdout() {
        let out = GitHubTokenProvider.shell("/bin/echo", ["  hi  "])
        XCTAssertEqual(out, "hi")
    }
}
