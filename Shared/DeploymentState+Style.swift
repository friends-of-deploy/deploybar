import SwiftUI

extension DeploymentState {
    /// The accent color used for status dots and badges.
    var tint: Color {
        switch self {
        case .ready:              return .green
        case .building, .queued:  return .orange
        case .error:              return .red
        case .canceled, .unknown: return .gray
        }
    }

    /// SF Symbol for the widget glyph. Distinct shapes per state, because the
    /// tinted desktop rendering mode drops colour and a plain dot would leave
    /// every state looking the same.
    var glyphSymbol: String {
        switch self {
        case .ready:    return "checkmark.circle.fill"
        case .building: return "circle.lefthalf.filled"
        case .queued:   return "clock.fill"
        case .error:    return "xmark.circle.fill"
        case .canceled: return "slash.circle"
        case .unknown:  return "circle.dotted"
        }
    }
}
