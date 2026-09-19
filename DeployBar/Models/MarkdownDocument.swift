import Foundation

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case unorderedListItem
        case orderedListItem(ordinal: Int)
        case code
        case quote
    }

    let id: Int
    let kind: Kind
    let indentationLevel: Int
    var content: AttributedString
}

enum MarkdownDocument {
    static func parse(_ markdown: String) throws -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attributed = try AttributedString(markdown: markdown, options: options)
        var blocks: [MarkdownBlock] = []

        for run in attributed.runs {
            guard let intent = run.presentationIntent,
                  let descriptor = blockDescriptor(for: intent) else { continue }

            var fragment = AttributedString(attributed[run.range])
            fragment.presentationIntent = nil

            if blocks.last?.id == descriptor.id {
                blocks[blocks.count - 1].content.append(fragment)
            } else {
                blocks.append(MarkdownBlock(id: descriptor.id,
                                            kind: descriptor.kind,
                                            indentationLevel: descriptor.indentationLevel,
                                            content: fragment))
            }
        }

        return blocks
    }

    private static func blockDescriptor(for intent: PresentationIntent) ->
        (id: Int, kind: MarkdownBlock.Kind, indentationLevel: Int)? {
        let components = intent.components

        if let item = components.first(where: {
            if case .listItem = $0.kind { return true }
            return false
        }), case let .listItem(ordinal) = item.kind {
            let isOrdered = components.contains { component in
                if case .orderedList = component.kind { return true }
                return false
            }
            return (item.identity,
                    isOrdered ? .orderedListItem(ordinal: ordinal) : .unorderedListItem,
                    max(0, intent.indentationLevel - 1))
        }

        guard let block = components.first else { return nil }
        let kind: MarkdownBlock.Kind
        if components.contains(where: { component in
            if case .blockQuote = component.kind { return true }
            return false
        }) {
            kind = .quote
        } else {
            switch block.kind {
            case let .header(level):
                kind = .heading(level: level)
            case .codeBlock:
                kind = .code
            default:
                kind = .paragraph
            }
        }
        return (block.identity, kind, max(0, intent.indentationLevel - 1))
    }
}
