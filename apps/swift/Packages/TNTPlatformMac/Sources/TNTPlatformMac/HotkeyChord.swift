// HotkeyChord — the chord the global hotkey listener reacts to. The
// string form (`"option+space"`) is the persisted contract for the
// `defaults write com.derekxwang.tnt.companion hotkey …` override path;
// round-tripping must be lossless.
//
// v0 only models the chord shape needed for ⌥Space. The `Key` enum is
// a closed set so unknown keys parse as `nil` rather than silently
// matching nothing at runtime.

import AppKit

public struct HotkeyChord: Sendable, Equatable {

    public enum Modifier: String, CaseIterable, Sendable, Equatable {
        case command
        case option
        case shift
        case control

        /// The bit on `CGEventFlags` that this modifier sets. Used by
        /// `HotkeyHost` to decide whether an incoming event matches the
        /// configured chord.
        public var cgFlag: CGEventFlags {
            switch self {
            case .command: return .maskCommand
            case .option:  return .maskAlternate
            case .shift:   return .maskShift
            case .control: return .maskControl
            }
        }
    }

    public enum Key: String, CaseIterable, Sendable, Equatable {
        case space

        /// macOS virtual key code for the key. v0 only needs `space`
        /// (kVK_Space = 49); add cases here when the hotkey config
        /// surface widens beyond the M0 milestone.
        public var cgKeyCode: UInt16 {
            switch self {
            case .space: return 49
            }
        }
    }

    public let modifiers: Set<Modifier>
    public let key: Key

    public init(modifiers: Set<Modifier>, key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Default chord for v0: `⌃⌥Space` (control+option+space).
    ///
    /// Deliberately three-key: the obvious two-key chords are all taken on
    /// a typical Mac — `⌘Space` is Spotlight, `⌥Space` is Raycast's default,
    /// `⌃Space` is the input-source switch. `⌃⌥Space` rarely collides.
    /// Override with `defaults write com.derekxwang.tnt.companion hotkey "…"`.
    public static let `default`: HotkeyChord = HotkeyChord(modifiers: [.control, .option], key: .space)

    /// Parse a string of the form `"option+space"`, `"control+space"`,
    /// `"option+command+space"`. Whitespace is trimmed and the string is
    /// lowercased before splitting on `+`. Unknown modifiers or unknown
    /// keys cause the parse to fail with `nil` so callers can fall back
    /// to `.default` cleanly.
    public static func parse(_ raw: String) -> HotkeyChord? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+").map(String.init)
        guard let last = parts.last,
              !last.isEmpty,
              let key = Key(rawValue: last) else { return nil }

        var mods: Set<Modifier> = []
        for raw in parts.dropLast() {
            guard let modifier = Modifier(rawValue: raw) else { return nil }
            mods.insert(modifier)
        }
        return HotkeyChord(modifiers: mods, key: key)
    }

    /// Reproducible string form. Modifiers are emitted in
    /// `Modifier.allCases` order so two chords that compare equal also
    /// serialise identically.
    public var displayString: String {
        let modList = Modifier.allCases.filter { modifiers.contains($0) }.map(\.rawValue)
        return (modList + [key.rawValue]).joined(separator: "+")
    }

    // MARK: - Event matching

    /// Whether a `keyDown` event *opens* this chord. Requires the
    /// configured key plus exactly the configured modifier set — a bare
    /// key (no modifiers) must never start a Voice Turn.
    ///
    /// Pure + `CGEventFlags`-only so the match policy is unit-testable
    /// without a `CGEventTap` (`HotkeyHost` is otherwise smoke-only).
    public func matchesKeyDown(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        guard keyCode == key.cgKeyCode else { return false }

        // Mask out caps-lock / numeric / help bits so a user with caps-
        // lock toggled isn't blocked from triggering the chord.
        let trackedMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        let active = flags.intersection(trackedMask)
        let expected = modifiers.reduce(into: CGEventFlags()) { $0.insert($1.cgFlag) }
        return active == expected
    }

    /// Whether a `keyUp` event *closes* this chord. Matches on the key
    /// alone — by the time the key's `keyUp` arrives the user has often
    /// already released the modifier, so requiring the modifier here would
    /// drop the release event and strand an open gesture (the M0
    /// modifier-release-ordering bug). Safe because the recognizer's
    /// `keyUp` is a no-op unless a matching `keyDown` opened the gesture.
    public func matchesKeyUp(keyCode: UInt16) -> Bool {
        keyCode == key.cgKeyCode
    }

    // MARK: - UserDefaults

    /// UserDefaults key the install reads on launch. Mirrors the value
    /// in the M0/S3 acceptance example:
    /// `defaults write com.derekxwang.tnt.companion hotkey …`.
    public static let userDefaultsKey: String = "hotkey"

    /// Load the configured chord from `UserDefaults`, falling back to
    /// `.default` when the key is absent or the stored value fails to
    /// parse. Side-effect-free.
    public static func load(
        from defaults: UserDefaults = .standard,
        key: String = HotkeyChord.userDefaultsKey
    ) -> HotkeyChord {
        guard let raw = defaults.string(forKey: key),
              let parsed = HotkeyChord.parse(raw) else {
            return .default
        }
        return parsed
    }
}
