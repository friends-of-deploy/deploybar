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
                        if store.sourcedDeployments.isEmpty {
                            EmptyListPlaceholder(label: "No deployments")
                        } else {
                            let allProjects = store.sourcedProjects.map(\.project)
                            ForEach(store.sourcedDeployments) { sourced in
                                HStack(spacing: 0) {
                                    DeploymentRow(
                                        deployment: sourced.deployment,
                                        faviconHost: DeploymentFavicon.host(for: sourced.deployment, in: allProjects),
                                        copyError: { await store.copyBuildError(for: $0) }
                                    )
                                    if store.connectedAccounts.count > 1 {
                                        SourceBadge(account: sourced.account)
                                            .padding(.trailing, 14)
                                    }
                                }
                            }
                        }
                    case .projects:
                        if store.sourcedProjects.isEmpty {
                            EmptyListPlaceholder(label: "No projects")
                        } else {
                            ForEach(store.sourcedProjects) { sourced in
                                HStack(spacing: 0) {
                                    ProjectRow(project: sourced.project, scopeName: store.scopeName, provider: sourced.account.provider)
                                    if store.connectedAccounts.count > 1 {
                                        SourceBadge(account: sourced.account)
                                            .padding(.trailing, 14)
                                    }
                                }
                            }
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
        case .deployments: return String(localized: "Deployments", comment: "Tab title")
        case .projects:    return String(localized: "Projects", comment: "Tab title")
        }
    }
}

// MARK: - Top bar (filter dropdown + actions)

private struct TopBar: View {
    @Bindable var store: DeploymentStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            filterMenu
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .tooltip(String(localized: "Settings", comment: "Button tooltip"))
            .pointingHandCursor()
            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .tooltip(String(localized: "Quit DeployBar", comment: "Button tooltip"))
            .pointingHandCursor()
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    /// Label reflects the active CLI scope (the one being polled).
    private var filterLabel: String {
        if let cli = store.connectedAccounts.first(where: { $0.source == .vercelCLI }) {
            return store.scopeName(accountId: cli.id, teamId: store.currentTeamId) ?? cli.label
        }
        return String(localized: "All", comment: "Filter: show all sources")
    }

    private var filterMenu: some View {
        Menu {
            // Per-provider sections: pick the account scope (personal / team) to view.
            ForEach(Provider.allCases, id: \.self) { provider in
                Section(provider.displayName) {
                    if provider.isImplemented {
                        let accounts = store.connectedAccounts.filter { $0.provider == provider }
                        ForEach(accounts) { account in
                            let scopes = store.scopes(for: account)
                            ForEach(scopes) { scope in
                                let isActive = account.source == .vercelCLI
                                    && scope.teamId == store.currentTeamId
                                Button {
                                    let name = store.scopeName(accountId: account.id, teamId: scope.teamId) ?? account.label
                                    Task { await store.switchScope(teamId: scope.teamId, scopeName: name) }
                                } label: {
                                    let name = store.scopeName(accountId: account.id, teamId: scope.teamId) ?? account.label
                                    if isActive {
                                        Label(name, systemImage: "checkmark")
                                    } else {
                                        Text(name)
                                    }
                                }
                            }
                        }
                    } else {
                        Text(String(localized: "\(provider.displayName) — coming soon", comment: "Placeholder for unimplemented provider"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Button(String(localized: "Manage accounts…", comment: "Opens account settings")) {
                openSettings()
            }
        } label: {
            Text("▲ \(filterLabel)").fontWeight(.bold)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingHandCursor()
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
                .tooltip(message)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Shared subviews

private struct EmptyListPlaceholder: View {
    let label: LocalizedStringKey

    var body: some View {
        Text(label)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 20)
    }
}
