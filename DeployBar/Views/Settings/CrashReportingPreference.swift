import SwiftUI

/// Shared by onboarding and General; there is only one persisted consent.
struct CrashReportingPreference: View {
    @Bindable var settings: SettingsStore
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.shareCrashReports) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share crash reports")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Help us fix problems by sending technical crash reports to Sentry.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Button("What is shared?") { showingDetails = true }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .popover(isPresented: $showingDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Crash report privacy").font(.headline)
                        Text("Reports include crash stack traces, app and macOS versions, and basic hardware information.")
                        Text("We exclude account details, tokens, repository names, deployment URLs, build logs, and usage statistics.")
                        Text("Reporting is optional. Turning it off stops reporting and deletes pending reports from this Mac. Reports already sent remain in Sentry.")
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
                    .frame(width: 340)
                }
        }
    }
}
