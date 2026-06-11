// DesiredSessionConfig — single source of truth for the session.update payload
// (issue #106, M4a).
//
// Builds the `SessionUpdate` that must be sent on every connect and every
// arm/clear event that changes the armed Appshot count. Having one function
// ensures the config is byte-identical on connect, on reconnect replay (#67),
// and on armed-state changes — no divergence possible.
//
// Composition: bilingualV0(voice:) base + Rewrite tools + read_screen_text
// (Tier-1 screen tool) + armed-context note injected into instructions when
// armedAppshotCount > 0.
//
// Pure: no app state reads; deterministic output (sortedKeys encoder not
// applied here — the raw JSONEncoder handles it; the golden test in
// the test target verifies byte-stability for identical inputs).

import Foundation

// MARK: - Builder

/// Build the desired `SessionUpdate` for the current state.
///
/// This is the single source of truth for what `session.update` must contain.
/// The controller calls this:
/// - On connect (before the first Voice Turn).
/// - On reconnect replay (after a transparent transport-level reconnect).
/// - On arm/clear events that change `armedAppshotCount`.
///
/// - Parameters:
///   - voice: The TTS voice identifier (e.g. `"marin"`). Reads from BYOK config.
///   - armedAppshotCount: The number of currently armed Appshots. When > 0,
///     `armedAppshotsContextNote(count:)` is appended to the system instructions.
/// - Returns: A fully composed `SessionUpdate` ready to send.
public func desiredSessionConfig(
    voice: String = "marin",
    armedAppshotCount: Int = 0
) -> SessionUpdate {
    var instructions = RealtimePrompts.v0System

    // Inject the armed-context note when Appshots are armed.
    let note = armedAppshotsContextNote(count: armedAppshotCount)
    if !note.isEmpty {
        instructions += "\n\n" + note
    }

    let base = SessionUpdate(
        session: SessionUpdate.Body(
            outputModalities: ["audio"],
            instructions: instructions,
            audio: SessionUpdate.Audio(
                input: SessionUpdate.AudioInput(),
                output: SessionUpdate.AudioOutput(voice: voice)
            )
        )
    )

    // Compose tools: Rewrite pair + Tier-1 screen tool.
    let body = base.session
        .withRewriteTools()
        .withScreenTools()

    return SessionUpdate(session: body)
}
