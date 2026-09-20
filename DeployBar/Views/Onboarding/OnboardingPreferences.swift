import SwiftUI
import UserNotifications

struct NotificationPermissionRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var requesting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "bell.badge").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deployment notifications").font(.system(size: 12, weight: .semibold))
                    Text("A heads-up when a build succeeds or fails.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if status == .authorized || status == .provisional {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityLabel(Text("Notifications enabled"))
                } else if status == .denied {
                    Button("Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.controlSize(.small)
                } else {
                    Button("Enable") { request() }.controlSize(.small).disabled(requesting)
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() {
        requesting = true
        errorMessage = nil
        Task { @MainActor in
            defer { requesting = false }
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                errorMessage = String(localized: "Couldn’t enable notifications. Please try again.")
            }
            await refresh()
        }
    }
}

struct LaunchAtLoginRow: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "power").font(.system(size: 18)).foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Launch at login").font(.system(size: 12, weight: .semibold))
                    Text("Ready whenever you open your Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Toggle("Launch at login", isOn: Binding(get: { enabled }, set: { value in
                    LaunchAtLogin.set(value)
                    enabled = LaunchAtLogin.isEnabled
                    failed = enabled != value
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if failed {
                Text("Check Login Items in System Settings to allow DeployBar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { enabled = LaunchAtLogin.isEnabled }
    }
}
