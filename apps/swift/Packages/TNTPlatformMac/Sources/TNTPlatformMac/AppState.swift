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
/// M0 shipped four states (idle/listening/thinking/speaking). M1 adds
/// `confirming` to hold a pending Rewrite between TNT speaking "…confirm?"
/// and the User answering. Adding more states requires updating every
/// mapping below and is a coordinated visual-design change, not a refactor.
/// Keep the case list closed.
public enum AppState: Sendable, Equatable, CaseIterable {
    /// Mic closed, no Voice Turn in flight.
    case idle
    /// Voice Provider is capturing the User's audio.
    case listening
    /// Cognitive Engine / Realtime model is producing a response.
    case thinking
    /// Voice Provider is speaking the response back.
    case speaking
    /// A Rewrite is pending User confirmation. TNT has spoken the
    /// cleaned prompt and is waiting for "yes" or "no." The pending
    /// Rewrite lives in `VoiceTurnFlow` — not in this enum.
    case confirming
}

public extension AppState {
    /// SF Symbol name for the menu-bar lamp icon.
    var symbolName: String {
        switch self {
        case .idle:       return "circle"
        case .listening:  return "waveform"
        case .thinking:   return "brain"
        case .speaking:   return "speaker.wave.2.fill"
        case .confirming: return "checkmark.circle"
        }
    }

    /// Typed tint for the lamp icon. Stays AppKit-free so the mapping is
    /// trivially testable; the AppKit binding lives on `AppStateTint`.
    var tint: AppStateTint {
        switch self {
        case .idle:       return .secondary
        case .listening:  return .green
        case .thinking:   return .orange
        case .speaking:   return .blue
        case .confirming: return .orange
        }
    }

    /// Title text shown at the top of the menu attached to the lamp.
    var menuTitle: String {
        switch self {
        case .idle:       return "TNT — idle"
        case .listening:  return "TNT — listening"
        case .thinking:   return "TNT — thinking"
        case .speaking:   return "TNT — speaking"
        case .confirming: return "TNT — confirming"
        }
    }
}
