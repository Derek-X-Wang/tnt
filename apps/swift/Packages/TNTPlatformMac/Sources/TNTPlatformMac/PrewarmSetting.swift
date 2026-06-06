// PrewarmSetting — single source of truth for the "warm the mic at launch"
// preference (issue #73). Default ON: on launch (when mic permission is
// already granted) the app starts+pauses the audio engine once so the user's
// FIRST Voice Turn resumes warm instead of paying the ~1.5s device cold-open.
//
// The trade is a brief mic indicator at launch. Default-on because instant
// first-turn matters more for a daily-driver voice agent; users who prefer no
// launch-time mic touch can disable it:
//   defaults write com.derekxwang.tnt.companion tnt.prewarm_mic -bool false
//
// A future settings UI ("test your mic" / configure) can surface this nicely.

import Foundation

public enum PrewarmSetting {

    /// UserDefaults key for the launch mic pre-warm preference.
    public static let userDefaultsKey: String = "tnt.prewarm_mic"

    /// Whether to pre-warm the mic at launch. Defaults to `true` when unset
    /// (default-on), so a fresh install gets instant first turns once mic
    /// permission is granted.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: userDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: userDefaultsKey)
    }
}
