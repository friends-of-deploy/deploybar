import SwiftUI

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    let accounts: AccountStore
    let store: DeploymentStore
    let settings: SettingsStore
    let finish: () -> Void
    let dismiss: () -> Void
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)
    }

    var body: some View {
        HStack(spacing: 0) {
            OnboardingArtwork(step: state.step)
                .frame(width: 330)
            VStack(alignment: .leading, spacing: 0) {
                progress
                    .padding(.bottom, 28)
                ZStack(alignment: .topLeading) {
                    page
                        .id(state.step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(x: movingForward ? 20 : -20).combined(with: .opacity),
                            removal: .offset(x: movingForward ? -12 : 12).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 780, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            OnboardingCloseButton(action: dismiss)
                .frame(width: 14, height: 14)
                .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onExitCommand(perform: dismiss)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingState.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= state.step.rawValue ? Color.accentColor : Color.primary.opacity(0.1))
                    .frame(width: step == state.step ? 28 : 8, height: 5)
            }
            Spacer()
            Text("\(state.step.rawValue + 1) of 3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(state.step.rawValue + 1) of 3"))
    }

    @ViewBuilder private var page: some View {
        switch state.step {
        case .welcome: welcome
        case .connect: connect
        case .preferences: preferences
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Your deployments.\nA glance away.", subtitle: "A little less tab switching. A lot more peace of mind.")
            VStack(alignment: .leading, spacing: 22) {
                feature("Everything in one place", detail: "All your project deployments in your menu bar.", symbol: "menubar.rectangle")
                feature("Stay in your flow", detail: "Know when a build succeeds or needs your attention.", symbol: "bell.badge")
                feature("Straight to what matters", detail: "Open a deployment or copy an error without digging through tabs.", symbol: "arrow.up.right.square")
            }
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Your tools, together.", subtitle: accounts.accounts.isEmpty
                    ? "DeployBar looks for your Vercel and GitHub CLI logins when it starts."
                    : "We found your accounts. You’re ready to follow their deployments.")
            VStack(spacing: 12) {
                ForEach(Provider.allCases.filter(\.isImplemented), id: \.self) { provider in
                    providerCard(provider)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("You can add or remove providers any time in the app settings:")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    SettingsNavigation.shared.showAccounts()
                } label: {
                    Label("Account Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.link)
            }
        }
    }

    private func providerCard(_ provider: Provider) -> some View {
        let detected = accounts.accounts.filter { $0.provider == provider }
        return HStack(spacing: 14) {
            Image(provider.iconAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .frame(width: 40, height: 40)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(provider.displayName).font(.system(size: 14, weight: .semibold))
                if detected.isEmpty {
                    Text(provider == .vercel ? "Sign in with vercel login, then restart DeployBar."
                         : "Sign in with gh auth login, then restart DeployBar.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if detected.count == 1 {
                    Text(detected[0].label).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).help(detected[0].label)
                } else {
                    Text("\(detected.count) accounts available")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: detected.isEmpty ? "minus.circle" : "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(detected.isEmpty ? Color.secondary : .green)
                .accessibilityLabel(Text(detected.isEmpty ? "Not detected" : "Account available"))
        }
        .padding(16)
        .frame(minHeight: 50)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    private var preferences: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heading("Make yourself at home.", subtitle: "DeployBar lives in your menu bar, ready when you need it.")
                VStack(spacing: 0) {
                    NotificationPermissionRow()
                    Divider().padding(.vertical, 16)
                    LaunchAtLoginRow()
                    Divider().padding(.vertical, 16)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "cross.case")
                            .font(.system(size: 18)).foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        CrashReportingPreference(settings: settings)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                Text("You can change these anytime in Settings.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        HStack {
            if state.step == .welcome {
                Button("Set up later", action: dismiss)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Button("Back") { move(to: state.step == .preferences ? .connect : .welcome) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: advance) {
                HStack(spacing: 8) {
                    Text(primaryTitle)
                    Image(systemName: "arrow.right")
                }
                .frame(minWidth: 116)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch state.step {
        case .welcome: return "Get started"
        case .connect: return accounts.accounts.isEmpty ? "Set up later" : "Continue"
        case .preferences: return "Start using DeployBar"
        }
    }

    private func advance() {
        switch state.step {
        case .welcome: move(to: .connect)
        case .connect: move(to: .preferences)
        case .preferences: finish()
        }
    }

    private func move(to step: OnboardingState.Step) {
        movingForward = step.rawValue > state.step.rawValue
        withAnimation(motion) { state.step = step }
    }

    private func heading(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    private func feature(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }
        }
    }
}

/// The real AppKit close control, embedded in the content instead of a title bar.
private struct OnboardingCloseButton: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])!
        button.target = context.coordinator
        button.action = #selector(Coordinator.close)
        button.toolTip = String(localized: "Close window")
        button.setAccessibilityLabel(String(localized: "Close window"))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func close() { action() }
    }
}
