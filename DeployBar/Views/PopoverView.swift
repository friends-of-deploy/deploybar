import SwiftUI

struct PopoverView: View {
    @Bindable var store: DeploymentStore
    var openSettings: () -> Void
    @State private var tab: PopoverTab = .deployments
    /// Which way the last tab change moved, so content slides toward the side
    /// the user came from rather than always the same direction.
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, openSettings: openSettings)

            TabSelector(tabs: PopoverTab.allCases, selection: $tab) { newTab in
                // Set direction before the selection changes, so the transition
                // built during this update already knows which way to slide.
                movingForward = newTab.order > tab.order
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .deployments:
                        deploymentsList(store.sourcedDeployments, empty: "No deployments")
                            .transition(slide)
                    case .projects:
                        projectsList
                            .transition(slide)
                    }
                }
            }
            .frame(height: 320)
            // The outgoing list slides out as the incoming one slides in; without
            // clipping they would both draw over the tab bar.
            .clipped()
        }
        .frame(width: 380)
        // Draws every tooltip in the popover. Installed here so a bubble can
        // overhang the row that triggered it — see `Tooltip.swift`.
        .tooltipHost()
        // Rounds the panel's window and keeps its height on the content.
        // `MenuBarExtra(.window)` does neither by itself.
        .background(PopoverPanelStyler())
        .onAppear {
            // Opening the popover acknowledges the current green/red icon alert.
            store.acknowledge()
        }
    }

    /// Asymmetric slide: the outgoing list exits the way the user is heading and
    /// the incoming one enters from the opposite edge, so the two tabs read as
    /// panels side by side rather than a cross-fade in place.
    private var slide: AnyTransition {
        // Reduce Motion: cross-fade the panes instead of sliding them across
        // the popover.
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing)
                .combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func deploymentsList(_ items: [SourcedDeployment], empty: LocalizedStringKey) -> some View {
        if items.isEmpty {
            // "Loading…" until the first poll lands, so a slow network doesn't
            // read as an empty account.
            EmptyListPlaceholder(label: store.isLoadingInitial ? "Loading…" : empty)
        } else {
            let allProjects = store.sourcedProjects.map(\.project)
            ForEach(items) { sourced in
                DeploymentRow(
                    deployment: sourced.deployment,
                    faviconHost: DeploymentFavicon.host(for: sourced.deployment, in: allProjects),
                    faviconDirectURL: DeploymentFavicon.directURL(for: sourced.deployment, in: allProjects),
                    copyError: { await store.copyBuildError(for: $0) },
                    scopeLabel: store.rowScopeLabel(accountId: sourced.account.id,
                                                    teamId: sourced.teamId),
                    scopeColorIndex: store.scopeColorIndex(accountId: sourced.account.id,
                                                           teamId: sourced.teamId)
                )
            }
            .animation(PopoverMotion.listUpdate(reduceMotion: reduceMotion), value: store.sourcedDeployments.map(\.id))
        }
    }

    @ViewBuilder
    private var projectsList: some View {
        if store.sourcedProjects.isEmpty {
            EmptyListPlaceholder(label: store.isLoadingInitial ? "Loading…" : "No projects")
        } else {
            ForEach(store.sourcedProjects) { sourced in
                // Use the project's OWN scope, not the global one: in "All"
                // `store.scopeName` is "all", which would build broken
                // dashboard links for a team-owned project.
                ProjectRow(project: sourced.project,
                           scopeName: store.scopeName(accountId: sourced.account.id,
                                                      teamId: sourced.teamId) ?? store.scopeName,
                           provider: sourced.account.provider,
                           latestRun: store.latestDeployment(for: sourced),
                           scopeLabel: store.rowScopeLabel(accountId: sourced.account.id,
                                                           teamId: sourced.teamId),
                           scopeColorIndex: store.scopeColorIndex(accountId: sourced.account.id,
                                                                  teamId: sourced.teamId),
                           // Set in every view, not only "All sources": the owner
                           // is part of the project's name, not a source marker.
                           ownerLabel: store.projectOwnerLabel(
                               accountId: sourced.account.id, teamId: sourced.teamId))
            }
            // Only rows entering or leaving move; a poll that returns the same
            // projects (the normal case) animates nothing, because the sorted
            // list is identical and `ForEach` identity is stable.
            .animation(PopoverMotion.listUpdate(reduceMotion: reduceMotion), value: store.sourcedProjects.map(\.id))
        }
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

    /// Left-to-right position, used to slide tab content toward the side the
    /// user moved from.
    var order: Int {
        switch self {
        case .deployments: return 0
        case .projects:    return 1
        }
    }
}

/// Shared timings, so the popover's motion reads as one system rather than a
/// handful of independently tuned animations.
enum PopoverMotion {
    /// Underline slide + content cross-slide. Spring rather than easing: the
    /// underline tracks a finger-flick gesture in feel, and a touch of
    /// overshoot-free settle keeps it crisp at this short duration.
    static let tabSwitch = Animation.spring(response: 0.28, dampingFraction: 0.86)

    /// A row arriving or leaving after a poll. Deliberately quiet: this fires
    /// while the user is reading the list, not in response to anything they did,
    /// so it should register as a change without pulling the eye off the row
    /// they were looking at.
    static let listUpdate = Animation.easeOut(duration: 0.22)

    /// Reduce Motion variants. The transitions these drive are positional
    /// (rows sliding in, panes cross-sliding), which is exactly what the
    /// setting asks us to drop — returning `nil` makes the change cut instead,
    /// so the state still updates without travelling across the popover.
    static func tabSwitch(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : tabSwitch
    }

    static func listUpdate(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : listUpdate
    }
}

// MARK: - Top bar (filter dropdown + actions)

private struct TopBar: View {
    @Bindable var store: DeploymentStore
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            filterMenu
            // Sits with the scope picker rather than the trailing actions: it
            // reports on the sources that picker selects from.
            HealthDot(
                issues: store.healthIssues,
                isRefreshing: store.isRefreshing,
                refresh: { Task { await store.poll() } }
            )
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

    /// Label reflects the selected scope (account + team).
    private var filterLabel: String {
        if case .scope(let accountId, let teamId) = store.filter,
           let name = store.rowScopeLabelIgnoringFilter(accountId: accountId, teamId: teamId) {
            return name
        }
        return String(localized: "All sources", comment: "Filter: show every provider and team")
    }

    private var filterMenu: some View {
        Menu {
            // Everything, across every provider and every Vercel team.
            Button {
                Task { await store.selectAll() }
            } label: {
                let name = String(localized: "All sources", comment: "Filter: show every provider and team")
                if store.filter == .all {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }

            // Per-provider sections: pick the account scope (personal / team) to view.
            ForEach(Provider.allCases, id: \.self) { provider in
                Section(provider.displayName) {
                    if provider.isImplemented {
                        let accounts = store.connectedAccounts.filter { $0.provider == provider }
                        ForEach(accounts) { account in
                            let scopes = store.scopes(for: account)
                            ForEach(scopes) { scope in
                                let isActive = store.filter == .scope(accountId: account.id, teamId: scope.teamId)
                                Button {
                                    Task { await store.select(accountId: account.id, teamId: scope.teamId) }
                                } label: {
                                    // Prefer the team's own display name; never fall
                                    // back to a raw "team_…" id in the menu.
                                    let name = scope.teamName
                                        ?? store.rowScopeLabelIgnoringFilter(accountId: account.id, teamId: scope.teamId)
                                        ?? account.label
                                    let indented = ScopeMenuLabel.text(name, isTeam: scope.teamId != nil)
                                    if isActive {
                                        Label(indented, systemImage: "checkmark")
                                    } else {
                                        Text(indented)
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
            Text(filterLabel).fontWeight(.bold)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointingHandCursor()
    }
}

// MARK: - Underlined tab selector

private struct TabSelector: View {
    let tabs: [PopoverTab]
    @Binding var selection: PopoverTab
    /// Called just before the selection changes, so the owner can record which
    /// direction the content should slide.
    let willSelect: (PopoverTab) -> Void
    /// Ties the single underline to whichever tab owns it, so selecting a
    /// neighbor slides the bar across instead of cutting to it.
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                TabButton(tab: tab, isSelected: selection == tab, namespace: underline) {
                    guard selection != tab else { return }
                    willSelect(tab)
                    withAnimation(PopoverMotion.tabSwitch(reduceMotion: reduceMotion)) { selection = tab }
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
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // The label is always laid out at semibold width and the weight
                // is faked by opacity, so selecting a tab cross-fades the
                // emphasis in place instead of reflowing the title (a real
                // `fontWeight` change resizes the text mid-animation, which
                // makes both labels visibly jitter).
                ZStack {
                    Text(tab.title)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .opacity(isSelected ? 0 : 1)
                    Text(tab.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.primary)
                        .opacity(isSelected ? 1 : 0)
                }
                .font(.body)
                // The ZStack sizes to the wider (semibold) copy; `fixedSize`
                // keeps that width instead of letting the tab's full-width
                // frame re-center the two layers independently.
                .fixedSize()
                underlineTrack
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder private var underlineTrack: some View {
        // Only the selected tab renders the bar; `matchedGeometryEffect` moves
        // that one view between tabs rather than fading two in and out.
        if isSelected {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .matchedGeometryEffect(id: "tabUnderline", in: namespace)
        } else {
            Color.clear.frame(height: 2)
        }
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

// MARK: - Scope menu labels

/// Indents a Vercel team under the account it belongs to in the scope menu.
///
/// A Vercel account's teams are sub-accounts of it, and the flat menu gave no
/// hint of that — a team read as a sibling of the account that owns it. SwiftUI
/// exposes no `indentationLevel` for menu items built from `Button`/`Text`
/// (the AppKit property exists on `NSMenuItem`, but the items here are
/// synthesized by SwiftUI), so the nesting is drawn with leading space.
enum ScopeMenuLabel {
    /// Spaces rather than a tab: menu items render in a proportional font where
    /// a tab's width is unspecified, while four spaces are predictable.
    static let indent = "    "

    static func text(_ name: String, isTeam: Bool) -> String {
        isTeam ? indent + name : name
    }
}
