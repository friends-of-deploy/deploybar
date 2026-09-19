import XCTest
@testable import DeployBar

final class MarkdownDocumentTests: XCTestCase {
    func test_parseKeepsHeadingsListsAndParagraphsAsSeparateBlocks() throws {
        let markdown = """
        ## Added

        - First item
        - **Second item**

        Read the [full changelog](https://example.com).
        """

        let blocks = try MarkdownDocument.parse(markdown)

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 2),
            .unorderedListItem,
            .unorderedListItem,
            .paragraph,
        ])
        XCTAssertEqual(blocks.map { String($0.content.characters) }, [
            "Added",
            "First item",
            "Second item",
            "Read the full changelog.",
        ])
    }

    func test_parsePreservesOrderedListOrdinals() throws {
        let blocks = try MarkdownDocument.parse("3. Third\n4. Fourth")

        XCTAssertEqual(blocks.map(\.kind), [
            .orderedListItem(ordinal: 3),
            .orderedListItem(ordinal: 4),
        ])
    }

    func test_parseRecognizesAQuotedParagraph() throws {
        let blocks = try MarkdownDocument.parse("> Important note")

        XCTAssertEqual(blocks.map(\.kind), [.quote])
        XCTAssertEqual(blocks.map { String($0.content.characters) }, ["Important note"])
    }
}
