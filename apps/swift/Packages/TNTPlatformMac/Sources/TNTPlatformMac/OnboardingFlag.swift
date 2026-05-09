// OnboardingFlag — single source of truth for the `tnt.has_onboarded`
// UserDefaults flag. The key is exposed publicly so the M0/S4 acceptance
// command (`defaults write com.tnt.app tnt.has_onboarded -bool true`)
// stays in lockstep with the code path.

import Foundation

public enum OnboardingFlag {

    /// UserDefaults key matching the M0/S4 acceptance criterion verbatim.
    public static let userDefaultsKey: String = "tnt.has_onboarded"

    public static func hasOnboarded(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: userDefaultsKey)
    }

    public static func setOnboarded(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: userDefaultsKey)
    }
}
