import SwiftUI

struct ChangelogSheet: View {
    @Environment(\.dismiss) private var dismiss

    let channel: UpdateChannel

    @State private var state: LoadState = .loading
    @State private var reloadID = 0

    private let loader = ChangelogLoader()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 620, height: 520)
        .task(id: reloadID) {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Changelog", comment: "Changelog sheet title"))
                    .font(.title2.weight(.semibold))
                Text(channel.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "Done", comment: "Close changelog sheet button")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView(String(localized: "Loading changelog…",
                                comment: "Changelog loading status"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(entries) where entries.isEmpty:
            ContentUnavailableView(
                String(localized: "No Releases", comment: "Empty changelog title"),
                systemImage: "doc.text",
                description: Text(String(localized: "No release notes are available for this channel.",
                                         comment: "Empty changelog explanation"))
            )

        case let .loaded(entries):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        release(entry)

                        if index < entries.count - 1 {
                            Divider()
                                .padding(.vertical, 20)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .failed:
            ContentUnavailableView {
                Label(String(localized: "Couldn’t Load Changelog",
                             comment: "Changelog loading error title"),
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(String(localized: "Check your internet connection and try again.",
                            comment: "Changelog loading error explanation"))
            } actions: {
                Button(String(localized: "Try Again", comment: "Retry changelog loading button")) {
                    reloadID &+= 1
                }
            }
        }
    }

    private func release(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "Version \(entry.version)",
                            comment: "Version heading in the changelog"))
                    .font(.title3.weight(.semibold))

                if let build = entry.build {
                    Text(String(localized: "Build \(build)",
                                comment: "Build number beside a changelog version"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            MarkdownText(entry.markdown)
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        do {
            let entries = try await loader.load(from: channel.appcastURL)
            guard !Task.isCancelled else { return }
            state = .loaded(entries)
        } catch is CancellationError {
            // Closing the sheet cancels its task; there is no error to show.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }
}

private struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                blockView(block)
                    .padding(.leading, CGFloat(block.indentationLevel) * 18)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            Text(block.content)
                .font(headingFont(level))
                .fontWeight(.semibold)

        case .paragraph:
            Text(block.content)

        case .unorderedListItem:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .frame(width: 12, alignment: .trailing)
                Text(block.content)
            }

        case let .orderedListItem(ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(ordinal).")
                    .frame(minWidth: 18, alignment: .trailing)
                Text(block.content)
            }

        case .code:
            Text(block.content)
                .font(.system(.body, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .quote:
            HStack(spacing: 10) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(block.content)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        if let parsed = try? MarkdownDocument.parse(markdown), !parsed.isEmpty {
            return parsed
        }
        return [MarkdownBlock(id: 0,
                              kind: .paragraph,
                              indentationLevel: 0,
                              content: AttributedString(markdown))]
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }
}

private extension ChangelogSheet {
    enum LoadState {
        case loading
        case loaded([ChangelogEntry])
        case failed
    }
}
