import XCTest
@testable import DeployBar

/// The tab bar is driven by the enum, so these pin the parts a visual glance
/// would otherwise have to catch: every tab has its own icon and its own title.
final class SettingsTabTests: XCTestCase {
    func test_tabOrderIsStable() {
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue),
                       ["general", "notifications", "accounts", "updates"])
    }

    /// Version and build moved to the Updates tab; leaving a copy behind in
    /// General would mean two places claiming to say what is installed.
    func test_updatesTabExists() {
        XCTAssertTrue(SettingsTab.allCases.contains(.updates))
    }

    func test_everyTabHasADistinctSymbol() {
        let symbols = SettingsTab.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count, "tabs must not share an icon")
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }

    func test_everyTabHasADistinctNonEmptyTitle() {
        let titles = SettingsTab.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "tabs must not share a title")
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }

    /// Projects moved inside the Accounts detail; a top-level Projects tab
    /// coming back would mean two places to follow a project.
    func test_projectsIsNotATopLevelTab() {
        XCTAssertFalse(SettingsTab.allCases.map(\.rawValue).contains("projects"))
    }
}

final class AccountDetailTabTests: XCTestCase {
    func test_segmentOrderIsStable() {
        XCTAssertEqual(AccountDetailTab.allCases.map(\.rawValue),
                       ["information", "projects"])
    }

    func test_everySegmentHasADistinctNonEmptyTitle() {
        let titles = AccountDetailTab.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "segments must not share a title")
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }
}

final class AccountSourceCaptionTests: XCTestCase {
    @MainActor
    func test_everySourceHasItsOwnCaption() {
        let captions = [
            Account.vercelCLI(id: UUID(), label: "V"),
            Account.githubCLI(id: UUID(), label: "G"),
            Account(id: UUID(), provider: .vercel, label: "T", source: .keychain(account: "k")),
        ].map(AccountsSettingsTab.sourceCaption)

        XCTAssertEqual(Set(captions).count, captions.count, "sources must not share a caption")
        XCTAssertFalse(captions.contains(where: \.isEmpty))
    }
}
