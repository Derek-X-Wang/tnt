// AppShotHotkeyGestureRecognizer — press-only recognizer for the Appshot Hotkey (M4a).
//
// Per CONTEXT.md (Appshot Hotkey): "A second global hotkey (default ⌃⌥⇧Space,
// configurable) whose single press captures an Appshot of the current frontmost
// window and arms it into the pending Capture Set. Unlike the voice hotkey it has
// no hold/tap distinction — one press, one capture."
//
// The recognizer:
// - Fires exactly one event on the FIRST `keyDown` of the chord.
// - Ignores auto-repeat `keyDown` events (key held).
// - Ignores `keyUp` — the gesture is complete on keyDown, not keyUp.
// - Never fires from a `keyDown` that was preceded by another unmatched `keyDown`
//   (i.e. a held key). The `isPressed` guard prevents duplicates.
//
// The superset-chord guard lives in `HotkeyChord.matchesKeyDown`: requiring the
// exact modifier set means ⌃⌥⇧Space will NOT match when the user presses ⌃⌥Space
// (only the subset modifiers are present). `HotkeyHost` handles both chords with the
// same `matchesKeyDown` logic — the modifiers are mutually exclusive by construction.
//
// Pure: testable without a CGEventTap, following the HotkeyGestureRecognizer pattern.

import Foundation

public struct AppShotHotkeyGestureRecognizer: Sendable, Equatable {

    /// The single effect this recognizer produces: one press = one capture.
    public enum Effect: Sendable, Equatable {
        /// Fire the Appshot capture. Emitted exactly once per distinct press.
        case captureAppshot
        /// No state change (auto-repeat, keyUp, or already-pressed guard).
        case noChange
    }

    /// Whether the Appshot chord key is currently physically held.
    /// Prevents auto-repeat `keyDown` events from firing multiple captures.
    public private(set) var isPressed: Bool = false

    public init() {}

    /// Apply a `keyDown` for the configured Appshot chord.
    ///
    /// Fires `.captureAppshot` on the FIRST `keyDown` only. Subsequent
    /// `keyDown` events (auto-repeat from holding the key) produce `.noChange`.
    public mutating func keyDown() -> Effect {
        guard !isPressed else { return .noChange }
        isPressed = true
        return .captureAppshot
    }

    /// Apply a `keyUp` for the configured Appshot chord.
    ///
    /// Always returns `.noChange` — the Appshot capture is already fired on
    /// `keyDown`; `keyUp` only resets the pressed guard so the next press works.
    @discardableResult
    public mutating func keyUp() -> Effect {
        isPressed = false
        return .noChange
    }
}

// MARK: - HotkeyChord — Appshot defaults

extension HotkeyChord {

    /// Default chord for the Appshot Hotkey: `⌃⌥⇧Space` (control+option+shift+space).
    ///
    /// Three tracked modifiers makes it a distinct, intentional gesture. It is a
    /// superset of the voice chord (⌃⌥Space) — `matchesKeyDown` requires the
    /// EXACT modifier set, so ⌃⌥Space presses cannot accidentally fire the Appshot
    /// chord and vice versa.
    ///
    /// Override with:
    /// `defaults write com.derekxwang.tnt.companion appshotHotkey "control+option+shift+space"`
    public static let appshotDefault: HotkeyChord = HotkeyChord(
        modifiers: [.control, .option, .shift],
        key: .space
    )

    /// UserDefaults key for the Appshot Hotkey chord. Separate from the voice
    /// chord key (`"hotkey"`) so both are independently configurable.
    public static let appshotUserDefaultsKey: String = "appshotHotkey"

    /// Load the configured Appshot chord from `UserDefaults`, falling back to
    /// `.appshotDefault` when the key is absent or the stored value fails to parse.
    public static func loadAppshot(
        from defaults: UserDefaults = .standard,
        key: String = HotkeyChord.appshotUserDefaultsKey
    ) -> HotkeyChord {
        guard let raw = defaults.string(forKey: key),
              let parsed = HotkeyChord.parse(raw) else {
            return .appshotDefault
        }
        return parsed
    }
}
