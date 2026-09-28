import XCTest
@testable import DeployBar

/// Guards the String Catalog: every source (English) key must carry a non-empty
/// Polish translation, so adding a new user-facing string without translating it
/// fails the build instead of silently shipping English to Polish users.
final class LocalizationTests: XCTestCase {

    // MARK: - Catalog completeness

    func test_everyEnglishKeyHasPolishTranslation() throws {
        let catalog = try loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty, "Catalog has no strings")

        var missing: [String] = []
        for (key, entryAny) in strings {
            guard let entry = entryAny as? [String: Any] else { continue }
            // A key with `shouldTranslate == false` is exempt.
            if let flag = entry["shouldTranslate"] as? Bool, flag == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            if !hasNonEmptyPolish(localizations) {
                missing.append(key)
            }
        }

        XCTAssertTrue(
            missing.isEmpty,
            "Keys missing a Polish translation:\n" + missing.sorted().joined(separator: "\n")
        )
    }

    /// Every string the Azure DevOps provider added has a Polish translation.
    func test_azureDevOpsStringsAreTranslated() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        let keys = [
            "Organization (optional)",
            "This token can’t list your organizations. Enter the organization name above.",
            "%@: couldn’t load organizations — retrying",
            "%@: this token can’t see any organization",
            "Pipelines",
            "Allow Build (Read), Code (Read) and Project and Team (Read). To follow every organization, also allow User Profile (Read).",
            "DeployBar looks for your CLI logins when it starts.",
            "Add it in Settings with a personal access token.",
            "Connect an account to keep your builds a glance away.",
        ]
        for key in keys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            XCTAssertTrue(hasNonEmptyPolish(localizations), "no Polish for: \(key)")
        }
    }

    // MARK: - Runtime label localization

    func test_deploymentStateLabelsAreNonEmpty() {
        for state in [DeploymentState.ready, .building, .queued, .error, .canceled] {
            XCTAssertFalse(state.label.isEmpty, "Empty label for \(state)")
        }
    }

    // MARK: - Widget catalog completeness

    func test_everyWidgetKeyHasPolishTranslation() throws {
        let catalog = try loadCatalog(directory: "DeployBarWidgets")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertFalse(strings.isEmpty, "Widget catalog has no strings")
        let missing = strings.compactMap { key, entryAny -> String? in
            guard let entry = entryAny as? [String: Any] else { return nil }
            if let flag = entry["shouldTranslate"] as? Bool, flag == false { return nil }
            return hasNonEmptyPolish(entry["localizations"] as? [String: Any] ?? [:]) ? nil : key
        }
        XCTAssertTrue(missing.isEmpty, "Widget keys missing Polish:\n" + missing.sorted().joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// Loads the raw String Catalog from the source tree. Xcode compiles
    /// `.xcstrings` into `.loctable` at build time, so the raw JSON is not in any
    /// bundle — we read it directly from disk relative to this test file instead.
    private func loadCatalog(directory: String = "DeployBar") throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)              // .../DeployBarTests/LocalizationTests.swift
        let repoRoot = testFile.deletingLastPathComponent()         // .../DeployBarTests
            .deletingLastPathComponent()                            // .../<repo root>
        let catalog = repoRoot
            .appendingPathComponent(directory)
            .appendingPathComponent("Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// True when the `pl` localization has a non-empty value, covering both plain
    /// `stringUnit` entries and pluralized `variations` entries.
    private func hasNonEmptyPolish(_ localizations: [String: Any]) -> Bool {
        guard let pl = localizations["pl"] as? [String: Any] else { return false }

        if let unit = pl["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return !value.isEmpty
        }

        if let variations = pl["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: Any] {
            // At least one plural category must carry a non-empty value.
            return plural.values.contains { categoryAny in
                guard let category = categoryAny as? [String: Any],
                      let unit = category["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { return false }
                return !value.isEmpty
            }
        }

        return false
    }
}
