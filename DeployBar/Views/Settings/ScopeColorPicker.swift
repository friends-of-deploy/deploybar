import SwiftUI

/// A color swatch that opens the scope palette on click.
///
/// Used in Settings › Accounts to override the marker color a scope shows in the
/// "All sources" popover. "Automatic" clears the override and returns the scope
/// to the color derived from its id.
///
/// Built from a `Button` + `popover` rather than a `Menu`. A `Menu` whose label
/// is a shape rather than text renders as nothing inside a grouped `Form` row:
/// `.borderlessButton` collapses the label to zero size, `.button` draws an
/// empty chip and the default style draws only its chevron. None of them show
/// the swatch, which left the picker invisible and unclickable. A plain button
/// draws its label as given, so the swatch stays visible and hittable.
struct ScopeColorPicker: View {
    let scopeId: String
    /// Every known scope id, so an un-overridden swatch shows the same color the
    /// popover row will.
    let allScopeIds: [String]
    let settings: SettingsStore
    /// Re-read on every change so the swatch and the rows stay in step.
    @Binding var overrides: [String: Int]

    @State private var isPresentingPalette = false

    private var selectedIndex: Int {
        overrides[scopeId] ?? ScopeColorIndex.index(for: scopeId, among: allScopeIds)
    }

    private var isAutomatic: Bool { overrides[scopeId] == nil }

    var body: some View {
        Button {
            isPresentingPalette = true
        } label: {
            swatch(color: ScopeColor.color(at: selectedIndex), diameter: 10)
                // The dot alone is a 10pt target; padding gives the click a
                // usable area without changing how big the dot looks.
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresentingPalette, arrowEdge: .bottom) {
            palette
        }
        .tooltip(String(localized: "Marker color", comment: "Scope color picker tooltip"))
        .pointingHandCursor()
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                settings.setScopeColor(nil, for: scopeId)
                overrides = settings.scopeColorOverrides
                isPresentingPalette = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        // Reserves the checkmark's width whether or not it shows,
                        // so the label doesn't shift between states.
                        .opacity(isAutomatic ? 1 : 0)
                    Text(String(localized: "Automatic",
                                comment: "Scope color: derived from the scope id"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Divider()

            HStack(spacing: 6) {
                ForEach(ScopeColor.palette.indices, id: \.self) { index in
                    Button {
                        settings.setScopeColor(index, for: scopeId)
                        overrides = settings.scopeColorOverrides
                        isPresentingPalette = false
                    } label: {
                        swatch(color: ScopeColor.color(at: index), diameter: 18)
                            .overlay {
                                // Marks the active slot on the swatch itself;
                                // a separate checkmark row would not fit here.
                                if !isAutomatic && selectedIndex == index {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                }
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(ScopeColor.names[index])
                    .pointingHandCursor()
                }
            }
        }
        .padding(12)
    }

    private func swatch(color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(
                Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}
