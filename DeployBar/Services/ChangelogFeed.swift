import Foundation

struct ChangelogEntry: Equatable, Identifiable, Sendable {
    let version: String
    let build: String?
    let markdown: String

    var id: String { [version, build].compactMap { $0 }.joined(separator: "-") }
}

enum ChangelogLoadError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

struct ChangelogLoader {
    typealias Fetch = (URL) async throws -> (Data, URLResponse)

    private let fetch: Fetch

    init(fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0) }) {
        self.fetch = fetch
    }

    func load(from url: URL) async throws -> [ChangelogEntry] {
        let (data, response) = try await fetch(url)
        guard let response = response as? HTTPURLResponse else {
            throw ChangelogLoadError.invalidResponse
        }
        guard 200..<300 ~= response.statusCode else {
            throw ChangelogLoadError.httpStatus(response.statusCode)
        }
        return try ChangelogFeedParser.parse(data)
    }
}

enum ChangelogFeedParser {
    static func parse(_ data: Data) throws -> [ChangelogEntry] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            throw parser.parserError ?? ChangelogFeedError.invalidXML
        }

        return delegate.entries
    }
}

private enum ChangelogFeedError: Error {
    case invalidXML
}

private final class ParserDelegate: NSObject, XMLParserDelegate {
    private(set) var entries: [ChangelogEntry] = []

    private var isInsideItem = false
    private var currentElement: String?
    private var text = ""
    private var version = ""
    private var build: String?
    private var markdown = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" {
            isInsideItem = true
            version = ""
            build = nil
            markdown = ""
            return
        }

        guard isInsideItem,
              ["title", "sparkle:version", "description"].contains(elementName) else { return }
        currentElement = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard currentElement != nil,
              let string = String(data: CDATABlock, encoding: .utf8) else { return }
        text += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "item" {
            if !version.isEmpty {
                entries.append(ChangelogEntry(version: version,
                                              build: build,
                                              markdown: markdown))
            }
            isInsideItem = false
            currentElement = nil
            return
        }

        guard elementName == currentElement else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            version = value
        case "sparkle:version":
            build = value.isEmpty ? nil : value
        case "description":
            markdown = value
        default:
            break
        }
        currentElement = nil
        text = ""
    }
}
