import SwiftUI

/// The real app screenshot sits on a white middle band. Only the panel's
/// ends carry color, so the screenshot's white canvas has no visible seam.
struct OnboardingArtwork: View {
    let step: OnboardingState.Step
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(red: 0.84, green: 0.95, blue: 0.92), location: 0),
                .init(color: .white, location: 0.17),
                .init(color: .white, location: 0.84),
                .init(color: Color(red: 0.88, green: 0.92, blue: 0.99), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                    Text("DeployBar").font(.system(size: 17, weight: .semibold)).tracking(-0.4)
                    Spacer()
                }
                .padding(.top, 48)
                .padding(.horizontal, 28)
                Spacer(minLength: 20)
                Image("OnboardingScreenshot")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // Trim the supplied canvas's horizontal whitespace to keep
                    // the popover legible while retaining its menu bar anchor.
                    .frame(width: 390)
                    .frame(width: 330)
                    .clipped()
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared || reduceMotion ? 0 : 10)
                Spacer(minLength: 20)
                VStack(spacing: 7) {
                    Text(caption).font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                    Text("Less checking. More creating.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)
            }
        }
        // This screenshot was captured in light appearance. Keep its panel
        // light too; the rest of the onboarding still follows macOS appearance.
        .environment(\.colorScheme, .light)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.06)).frame(width: 1) }
        .accessibilityHidden(true)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.86)) {
                appeared = true
            }
        }
    }

    private var caption: LocalizedStringKey {
        switch step {
        case .welcome: return "Small icon. Big peace of mind."
        case .connect: return "Your tools, together."
        case .preferences: return "Right here when you need it."
        }
    }
}
