import os
import SwiftUI
import WidgetKit

let widgetTimelineLog = Logger(subsystem: "io.eightlines.deploybar.widgets", category: "timeline")

/// State glyph. Static — widgets don't run `repeatForever` animations — and
/// accentable so it keeps meaning in the tinted desktop mode.
struct StatusGlyph: View {
    let state: DeploymentState
    var size: CGFloat = 12
    var isStale = false

    var body: some View {
        Image(systemName: state.glyphSymbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isStale ? Color.secondary : state.tint)
            .widgetAccentable()
    }
}

/// "Building (last known)" when stale, so an old in-progress state never reads as live.
func stateText(_ state: DeploymentState, isStale: Bool) -> String {
    guard isStale, state.isInProgress else { return state.label }
    return String(localized: "\(state.label) (last known)")
}

func targetText(_ target: String?) -> String? {
    guard let target else { return nil }
    return target == "production" ? String(localized: "Production") : String(localized: "Preview")
}

/// Elapsed build timer while running and fresh; otherwise time since the deploy.
/// Both styles are re-rendered by WidgetKit itself, costing no reloads.
struct DeployTime: View {
    let deployment: WidgetDeployment
    let isStale: Bool

    var body: some View {
        if deployment.state.isInProgress && !isStale {
            Text(deployment.buildingAt ?? deployment.createdAt, style: .timer)
                .monospacedDigit()
        } else {
            Text(deployment.readyAt ?? deployment.createdAt, style: .relative)
        }
    }
}

struct StaleFooter: View {
    let generatedAt: Date

    var body: some View {
        Text("Updated \(Text(generatedAt, style: .relative)) ago")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct WidgetMessage: View {
    let text: LocalizedStringKey
    let systemImage: String

    init(_ text: LocalizedStringKey, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A `Link` when there's somewhere to go, plain content otherwise.
struct OptionalLink<Label: View>: View {
    let url: URL?
    @ViewBuilder let label: () -> Label

    var body: some View {
        if let url {
            Link(destination: url, label: label)
        } else {
            label()
        }
    }
}

struct ProjectTitle: View {
    let project: WidgetProject

    var body: some View {
        HStack(spacing: 5) {
            Image(project.provider.iconAssetName)
                .resizable().renderingMode(.template).scaledToFit()
                .frame(width: 12, height: 12)
                .foregroundStyle(.secondary)
            Text(project.name).font(.headline).lineLimit(1)
        }
    }
}
