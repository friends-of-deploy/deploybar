import XCTest
@testable import DeployBar

final class ChangelogFeedTests: XCTestCase {
    func test_parseReturnsEveryReleaseInFeedOrder() throws {
        let feed = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>DeployBar</title>
            <item>
              <title>1.2.0</title>
              <sparkle:version>12</sparkle:version>
              <description sparkle:format="markdown"><![CDATA[
        ## Added

        - A useful thing.
        ]]></description>
            </item>
            <item>
              <title>1.1.0</title>
              <sparkle:version>11</sparkle:version>
              <description sparkle:format="markdown"><![CDATA[
        Fixed **everything**.
        ]]></description>
            </item>
          </channel>
        </rss>
        """.utf8)

        let releases = try ChangelogFeedParser.parse(feed)

        XCTAssertEqual(releases, [
            ChangelogEntry(version: "1.2.0", build: "12", markdown: "## Added\n\n- A useful thing."),
            ChangelogEntry(version: "1.1.0", build: "11", markdown: "Fixed **everything**."),
        ])
    }

    func test_parseRejectsMalformedXML() {
        let malformedFeed = Data("<rss><channel><item></rss>".utf8)

        XCTAssertThrowsError(try ChangelogFeedParser.parse(malformedFeed))
    }

    func test_loaderFetchesAndParsesTheSelectedFeed() async throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://example.com/appcast-beta.xml"))
        let feed = Data("""
        <rss version="2.0">
          <channel>
            <item>
              <title>2.0.0-beta.1</title>
              <description><![CDATA[Beta notes.]]></description>
            </item>
          </channel>
        </rss>
        """.utf8)
        let loader = ChangelogLoader { url in
            XCTAssertEqual(url, expectedURL)
            return (feed, HTTPURLResponse(url: url,
                                          statusCode: 200,
                                          httpVersion: nil,
                                          headerFields: nil)!)
        }

        let releases = try await loader.load(from: expectedURL)

        XCTAssertEqual(releases, [
            ChangelogEntry(version: "2.0.0-beta.1", build: nil, markdown: "Beta notes."),
        ])
    }

    func test_loaderRejectsAnHTTPErrorResponse() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/appcast.xml"))
        let loader = ChangelogLoader { url in
            (Data(), HTTPURLResponse(url: url,
                                     statusCode: 503,
                                     httpVersion: nil,
                                     headerFields: nil)!)
        }

        do {
            _ = try await loader.load(from: url)
            XCTFail("Expected an HTTP error")
        } catch let error as ChangelogLoadError {
            XCTAssertEqual(error, .httpStatus(503))
        }
    }
}
