import SwiftUI

struct OnboardingEmptyState: View {
    let openOnboarding: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Your next deployment, right here.")
                    .font(.system(size: 18, weight: .semibold)).tracking(-0.4)
                    .multilineTextAlignment(.center)
                Text("Connect Vercel or GitHub to keep your builds a glance away.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Set up DeployBar", action: openOnboarding)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 4)
            Text("Already signed in with a CLI? Restart DeployBar to detect it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .frame(height: 354)
    }
}
