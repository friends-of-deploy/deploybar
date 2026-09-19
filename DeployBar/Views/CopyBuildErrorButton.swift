import SwiftUI

/// Copies a failed deployment's build error to the clipboard, ready to paste
/// into an AI. Mirrors `IconActionButton`'s layout (fixed-size symbol inside the
/// shared hit area) so the icon stays aligned with the other action icons even
/// as its glyph swaps between states.
struct CopyBuildErrorButton: View {
    let deployment: Deployment
    /// Fetches the build log and copies the report. Returns true on success.
    let copyError: (Deployment) async -> Bool

    @State private var state: CopyState = .idle

    enum CopyState { case idle, copying, copied, failed }

    var body: some View {
        Button(action: run) {
            // `actionIconHitArea` centers the glyph in a uniform square, so the
            // symbol swapping (clipboard → checkmark → triangle) never nudges
            // the row and the icon lines up with the neighboring link icons.
            ActionIcon(systemName: symbol)
        }
        .buttonStyle(.plain)
        .disabled(state == .copying)
        .tooltip(tooltip)
        .pointingHandCursor()
    }

    private var symbol: String {
        switch state {
        case .idle, .copying: return "doc.on.clipboard"
        case .copied:         return "checkmark"
        case .failed:         return "exclamationmark.triangle"
        }
    }

    private var tooltip: String {
        switch state {
        case .idle:    return "Copy build error for AI"
        case .copying: return "Fetching build log…"
        case .copied:  return "Copied!"
        case .failed:  return "Couldn't fetch the build log"
        }
    }

    private func run() {
        guard state != .copying else { return }
        state = .copying
        Task {
            let ok = await copyError(deployment)
            state = ok ? .copied : .failed
            try? await Task.sleep(for: .seconds(2))
            state = .idle
        }
    }
}
