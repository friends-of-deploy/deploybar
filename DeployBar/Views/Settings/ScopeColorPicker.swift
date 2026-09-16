import SwiftUI

/// A color swatch that opens the scope palette on click.
///
/// Used in Settings › Accounts to override the marker color a scope shows in the
/// "All sources" popover. "Automatic" clears the override and returns the scope
/// to the color derived from its id.
struct ScopeColorPicker: View {
    let scopeId: String
    /// Every known scope id, so an un-overridden swatch shows the same color the
    /// popover row will.
    let allScopeIds: [String]
    let settings: SettingsStore
    /// Re-read on every change so the swatch and the rows stay in step.
    @Binding var overrides: [String: Int]

    private var selectedIndex: Int {
        overrides[scopeId] ?? ScopeColorIndex.index(for: scopeId, among: allScopeIds)
    }

    private var isAutomatic: Bool { overrides[scopeId] == nil }

    var body: some View {
        Menu {
            Button {
                settings.setScopeColor(nil, for: scopeId)
                overrides = settings.scopeColorOverrides
            } label: {
                if isAutomatic {
                    Label(String(localized: "Automatic", comment: "Scope color: derived from the scope id"),
                          systemImage: "checkmark")
                } else {
                    Text(String(localized: "Automatic", comment: "Scope color: derived from the scope id"))
                }
            }

            Divider()

            ForEach(ScopeColor.palette.indices, id: \.self) { index in
                Button {
                    settings.setScopeColor(index, for: scopeId)
                    overrides = settings.scopeColorOverrides
                } label: {
                    // A filled SF Symbol renders in the menu's tint, so the
                    // swatch has to come from the label text itself.
                    if !isAutomatic && selectedIndex == index {
                        Label(ScopeColor.names[index], systemImage: "checkmark")
                    } else {
                        Text(ScopeColor.names[index])
                    }
                }
            }
        } label: {
            Circle()
                .fill(ScopeColor.color(at: selectedIndex))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tooltip(String(localized: "Marker color", comment: "Scope color picker tooltip"))
        .pointingHandCursor()
    }
}
