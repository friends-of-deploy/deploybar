import SwiftUI

struct PopoverView: View {
    @Bindable var store: DeploymentStore
    var openSettings: () -> Void
    @State private var tab: PopoverTab = .deployments

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, openSettings: openSettings)

            TabSelector(selection: $tab)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .deployments:
                        if store.deployments.isEmpty {
                            EmptyListPlaceholder(label: "No deployments")
                        } else {
                            ForEach(store.deployments) { deployment in
                                DeploymentRow(
                                    deployment: deployment,
                                    faviconHost: DeploymentFavicon.host(for: deployment, in: store.projects)
                                )
                            }
                        }
                    case .projects:
                        if store.projects.isEmpty {
                            EmptyListPlaceholder(label: "No projects")
                        } else {
                            ForEach(store.projects) { ProjectRow(project: $0, scopeName: store.scopeName) }
                        }
                    }
                }
            }
            .frame(height: 320)

            if let error = store.errorMessage {
                Divider()
                StatusBar(message: error)
            }
        }
        .frame(width: 380)
    }
}

enum PopoverTab: CaseIterable {
    case deployments, projects
    var title: String {
        switch self {
        case .deployments: return "Deployments"
        case .projects:    return "Projects"
        }
    }
}

// MARK: - Top bar (team switcher + actions)

private struct TopBar: View {
    @Bindable var store: DeploymentStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            teamMenu
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .pointingHandCursor()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("Quit VercelBar")
            .pointingHandCursor()
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    private var teamMenu: some View {
        Menu {
            Button { switchTo(nil, name: "personal") } label: {
                if store.currentTeamId == nil {
                    Label("Personal", systemImage: "checkmark")
                } else {
                    Text("Personal")
                }
            }
            if !store.teams.isEmpty {
                Divider()
                ForEach(store.teams) { team in
                    let name = team.slug ?? team.name ?? team.id
                    Button { switchTo(team.id, name: name) } label: {
                        if store.currentTeamId == team.id {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Text("▲ \(store.scopeName)").fontWeight(.bold)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingHandCursor()
    }

    private func switchTo(_ teamId: String?, name: String) {
        Task { await store.switchScope(teamId: teamId, scopeName: name) }
    }
}

// MARK: - Underlined tab selector

private struct TabSelector: View {
    @Binding var selection: PopoverTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PopoverTab.allCases, id: \.self) { tab in
                TabButton(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabButton: View {
    let tab: PopoverTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(tab.title)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: - Bottom status bar (errors/warnings only)

private struct StatusBar: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Shared subviews

private struct EmptyListPlaceholder: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }
}
