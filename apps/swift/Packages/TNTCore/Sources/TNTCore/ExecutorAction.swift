// ExecutorAction — the closed enum contract between the decider (Cognitive
// Engine / Realtime model, server-future) and the performer (MacActionExecutor,
// permanent client). This is the seam ADR-0007 locks: the decider selects
// one action from the enum; the Executor only performs it. Autonomy grows
// behind the Cognitive Engine seam (ADR-0007 decision 3), not by making
// the Executor smarter.
//
// Per ADR-0007:
//   decision 1 — v0 ships activateApp/focusWindow/pasteText/pressReturn;
//                type(String)/keystroke deferred until the target guard is proven.
//   decision 5 — never run(String); the enum is the firewall.
//   decision 6 — every action carries a target binding captured at decision
//                time and re-checked immediately before acting (focus-race guard).
//   decision 7 — blastRadius drives the confirm tier:
//                reversible → just happens; confirmRequired → one spoken confirm/turn.
//
// AgentRef is reused for Worker Agent targets (claude-code, cursor, etc.).
// For system targets (the TNT app itself, arbitrary bundle IDs) the bundleID
// string is the binding.

import Foundation

// MARK: - Target binding

/// The intended target of an executor action, captured at decision time
/// and re-verified immediately before acting (ADR-0007 decision 6).
/// Mismatch → abort with `ActionResult.targetChanged`.
public enum ActionTarget: Codable, Equatable, Sendable {
    /// A known Worker Agent identified by its `AgentRef`.
    case agent(AgentRef)
    /// An arbitrary macOS application identified by its bundle ID.
    case bundleID(String)
    /// The TNT Desktop App itself.
    case tntApp
}

// MARK: - ExecutorAction

/// A closed enum of scoped OS actions TNT can perform on the User's behalf.
///
/// The enum is the contract between decider and hands (ADR-0007). Never
/// add `run(String)` or any variant that allows arbitrary command execution.
/// `type(String)` / `keystroke` are deferred until the target guard is proven
/// (ADR-0007 decision 5).
public enum ExecutorAction: Sendable, Equatable {

    // MARK: - Reversible actions (blastRadius = .reversible)

    /// Bring the target application to the foreground.
    /// Reversible — the user can simply switch away.
    case activateApp(ActionTarget)

    /// Focus the target application's frontmost window.
    /// Reversible — no content is modified or sent.
    case focusWindow(target: ActionTarget)

    // MARK: - Irreversible / exfiltrating actions (blastRadius = .confirmRequired)

    /// Set the system pasteboard to `text` and synthesize ⌘V to paste
    /// it into the target window. Per ADR-0004 amendment: TNT may write
    /// the pasteboard for a confirmed Voice Action, but still never reads it.
    case pasteText(String, target: ActionTarget)

    /// Synthesize the Return key in the target window (e.g. to submit a
    /// pasted prompt to a Worker Agent's input field).
    case pressReturn(target: ActionTarget)
}

// MARK: - BlastRadius

/// Blast radius classification for an executor action.
/// Drives the confirmation tier (ADR-0007 decision 7):
/// - `reversible` → just happens; TNT announces what it did.
/// - `confirmRequired` → one spoken confirm per turn before acting;
///   never per-keystroke.
public enum BlastRadius: Sendable, Equatable {
    case reversible
    case confirmRequired
}

extension ExecutorAction {
    /// Data-driven confirmation tier for this action (ADR-0007 decision 7).
    public var blastRadius: BlastRadius {
        switch self {
        case .activateApp, .focusWindow:
            return .reversible
        case .pasteText, .pressReturn:
            return .confirmRequired
        }
    }
}

// MARK: - ActionResult

/// Structured outcome of an executor action. The model receives this
/// as the `function_call_output` for the executor tool call.
///
/// Per ADR-0007 decision 4: results return status only — **never a
/// screenshot**. This is the structural firewall preventing the narrow
/// allowlist from drifting into autonomous GUI puppeteering.
public enum ActionResult: Codable, Equatable, Sendable {
    /// The action completed successfully.
    case done

    /// The action requires explicit user confirmation before executing.
    /// The model should speak the confirm prompt and wait for an affirm.
    case needsConfirmation

    /// The frontmost application changed between decision and execution
    /// (the target-window race, same bug class as issue #27). TNT offers
    /// to focus the original target first before retrying.
    case targetChanged

    /// The required macOS TCC permission (Accessibility, Input Monitoring)
    /// was not granted. TNT should surface a recovery message.
    case permissionMissing

    /// The action is not in the v0 allowlist or is otherwise unsupported.
    case unsupported

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type_ = try container.decode(String.self, forKey: .type)
        switch type_ {
        case "done":               self = .done
        case "needs_confirmation": self = .needsConfirmation
        case "target_changed":     self = .targetChanged
        case "permission_missing": self = .permissionMissing
        case "unsupported":        self = .unsupported
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown ActionResult type: \(type_)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .done:               try container.encode("done",               forKey: .type)
        case .needsConfirmation:  try container.encode("needs_confirmation", forKey: .type)
        case .targetChanged:      try container.encode("target_changed",     forKey: .type)
        case .permissionMissing:  try container.encode("permission_missing", forKey: .type)
        case .unsupported:        try container.encode("unsupported",        forKey: .type)
        }
    }
}
