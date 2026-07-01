import SwiftUI

/// A compact capsule identifying the provider/account source of a row.
/// Shown only when more than one account is connected.
struct SourceBadge: View {
    let account: Account

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: account.provider.iconName).imageScale(.small)
            Text(account.label).lineLimit(1)
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
    }
}
