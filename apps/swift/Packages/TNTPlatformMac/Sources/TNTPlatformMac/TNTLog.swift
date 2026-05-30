// TNTLog — os.Logger handles for the macOS app. Routes through the
// unified logging system so launch + permission + hotkey behavior is
// inspectable with:
//
//   log show --last 3m --predicate 'subsystem == "com.derekxwang.tnt"' --info --debug
//   log stream --predicate 'subsystem == "com.derekxwang.tnt"' --info --debug
//
// os_log (unlike print) survives a GUI launch with no attached terminal,
// which is exactly the case when the app is started via LaunchServices
// (`open`) or double-click. Keep messages free of user keystroke content —
// the hotkey path only ever logs the chord key, never arbitrary input.

import os

public enum TNTLog {
    public static let app = Logger(subsystem: "com.derekxwang.tnt", category: "app")
    public static let hotkey = Logger(subsystem: "com.derekxwang.tnt", category: "hotkey")
    public static let voice = Logger(subsystem: "com.derekxwang.tnt", category: "voice")
}
