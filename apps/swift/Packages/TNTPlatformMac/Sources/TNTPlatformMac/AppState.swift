// AppState — the State Lamp model.
//
// One value per visible Personal Master Agent state. The lamp lives in the
// menu bar (via `MenuBarHost`) and is the single way the User can tell what
// TNT is doing right now without reading any text. Mappings to SF Symbol,
// tint, and menu title are pure functions on the case so future slices can
// flip the lamp without re-validating the visual contract.

import Foundation

/// The single Voice-Turn-aware state shown by the State Lamp.
///
/// v0 has exactly four visible states; adding a fifth requires updating
/// every mapping below and is a coordinated visual-design change, not a
/// refactor. Keep the case list closed.
public enum AppState: Sendable, Equatable, CaseIterable {
    /// Mic closed, no Voice Turn in flight.
    case idle
    /// Voice Provider is capturing the User's audio.
    case listening
    /// Cognitive Engine / Realtime model is producing a response.
    case thinking
    /// Voice Provider is speaking the response back.
    case speaking
}

public extension AppState {
    /// SF Symbol name for the menu-bar lamp icon.
    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .listening: return "waveform"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        }
    }

    /// Typed tint for the lamp icon. Stays AppKit-free so the mapping is
    /// trivially testable; the AppKit binding lives on `AppStateTint`.
    var tint: AppStateTint {
        switch self {
        case .idle: return .secondary
        case .listening: return .green
        case .thinking: return .orange
        case .speaking: return .blue
        }
    }

    /// Title text shown at the top of the menu attached to the lamp.
    var menuTitle: String {
        switch self {
        case .idle: return "TNT — idle"
        case .listening: return "TNT — listening"
        case .thinking: return "TNT — thinking"
        case .speaking: return "TNT — speaking"
        }
    }
}
