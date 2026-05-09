// AppStateTint — typed colour tokens for the State Lamp.
//
// Sits between `AppState` (semantic) and `NSColor` (visual) so the mapping
// from state to colour is testable without instantiating AppKit values.
// `AppStateTint.nsColor` is the only place that touches AppKit colour APIs.

import AppKit

public enum AppStateTint: Sendable, Equatable {
    case secondary
    case green
    case orange
    case blue
}

public extension AppStateTint {
    /// AppKit binding used by `MenuBarHost` to paint the lamp icon.
    var nsColor: NSColor {
        switch self {
        case .secondary: return .secondaryLabelColor
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .blue: return .systemBlue
        }
    }
}
