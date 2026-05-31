// ProjectHeuristic — pure string-based heuristic to derive a ProjectRef
// from a frontmost window's app name + title. No AppKit, no Accessibility
// tree walking — just string parsing so the logic is fully unit-testable.
//
// v0 supports four app families:
//   VS Code / Cursor: "file.swift — tnt" or "● file.swift — tnt — Workspace"
//   JetBrains IDEs:  "tnt – src/Main.kt" (en-dash separator)
//   Terminal / iTerm2: "user@host: ~/path/tnt" or "/Users/user/path/tnt"
//   Unknown / unparseable → nil (no crash, no garbage ProjectRef)
//
// Each family's strategy is kept as a small private function for
// readability and independent unit-testability. The public API is a
// single dispatch function.

import Foundation
import TNTCore

// MARK: - Public API

/// Derive a `ProjectRef` from the frontmost window's `appName` and
/// `windowTitle`, using per-app heuristics. Returns `nil` when the
/// app is unknown or the title is unparseable. Never crashes.
///
/// Call sites: `CaptureSetAssembler` (#48) passes the raw values
/// already obtained from the Accessibility client. This function
/// performs no AX reads itself.
public func projectRef(appName: String, windowTitle: String) -> ProjectRef? {
    let app = appName.lowercased()
    let title = windowTitle.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }

    switch true {
    case vsCodeFamily(app):
        return vscodeProject(from: title)
    case jetbrainsFamily(app):
        return jetbrainsProject(from: title)
    case terminalFamily(app):
        return terminalProject(from: title)
    default:
        return nil
    }
}

// MARK: - App family detection

private func vsCodeFamily(_ app: String) -> Bool {
    app == "cursor" || app == "code" || app.contains("visual studio code")
}

private func jetbrainsFamily(_ app: String) -> Bool {
    let jetbrainsApps = [
        "intellij idea", "pycharm", "webstorm", "goland",
        "rubymine", "clion", "rider", "datagrip", "fleet",
        "phpstorm", "appcode", "idea"
    ]
    return jetbrainsApps.contains(where: { app.contains($0) })
}

private func terminalFamily(_ app: String) -> Bool {
    app == "terminal" || app == "iterm2" || app == "iterm" ||
    app == "warp" || app == "alacritty" || app == "kitty" ||
    app == "ghostty"
}

// MARK: - VS Code / Cursor strategy

/// VS Code / Cursor title format:
///   `"VoiceTurnController.swift — tnt"` → name = "tnt"
///   `"● VoiceTurnController.swift — tnt"` → name = "tnt"  (unsaved marker)
///   `"VoiceTurnController.swift — tnt — Workspace"` → name = "tnt"
///   `"VoiceTurnController.swift — tnt [Administrator]"` → name = "tnt"
///   `"Welcome"` → nil (no project in title)
///
/// Strategy: split on em-dash ` — ` (U+2014 with spaces), take the
/// last meaningful segment, strip noise words.
private func vscodeProject(from title: String) -> ProjectRef? {
    // Remove unsaved-file marker.
    var clean = title
    if clean.hasPrefix("●") || clean.hasPrefix("•") {
        clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    // Split on " — " (U+2014). If there are no separators, there's
    // no project name in the title (e.g. "Welcome").
    let separator = " \u{2014} " // " — "
    let parts = clean.components(separatedBy: separator).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard parts.count >= 2 else { return nil }

    // The project name is the second segment (parts[1]).
    // Strip trailing noise: " Workspace", " [Administrator]".
    var name = parts[1]
    let noisePatterns = [" — Workspace", " - Workspace", " Workspace",
                         " [Administrator]", " (Administrator)"]
    for noise in noisePatterns {
        if name.hasSuffix(noise) {
            name = String(name.dropLast(noise.count))
        }
    }
    name = name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    return ProjectRef(name: name)
}

// MARK: - JetBrains strategy

/// JetBrains title format:
///   `"tnt – src/main/kotlin/Main.kt"` → name = "tnt" (en-dash U+2013)
///   `"tnt"` (no separator) → name = "tnt"
///
/// Strategy: split on " – " (en-dash, U+2013), take the first segment.
private func jetbrainsProject(from title: String) -> ProjectRef? {
    let enDashSeparator = " \u{2013} " // " – "
    let parts = title.components(separatedBy: enDashSeparator)
    let name = parts[0].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    return ProjectRef(name: name)
}

// MARK: - Terminal / iTerm2 strategy

/// Terminal title formats:
///   `"user@host: ~/path/tnt"` → name = "tnt", path = "~/path/tnt"
///   `"~/projects/tnt"` → name = "tnt", path = "~/projects/tnt"
///   `"/Users/dev/projects/tnt"` → name = "tnt", path = "/Users/dev/projects/tnt"
///   `"bash"` or `"zsh"` → nil
///
/// Strategy: after stripping a `user@host: ` prefix, take the last
/// path component as the name. Collapse `~` to a human-readable form.
private func terminalProject(from title: String) -> ProjectRef? {
    var pathString = title

    // Strip "user@host: " prefix if present.
    if let colonRange = pathString.range(of: ": ") {
        let prefix = pathString[..<colonRange.lowerBound]
        // Accept the strip only if the prefix looks like "user@host"
        // (contains "@" and no "/").
        if prefix.contains("@") && !prefix.contains("/") {
            pathString = String(pathString[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        }
    }

    // Reject bare shell names that don't look like paths.
    let bareNames: Set<String> = ["bash", "zsh", "fish", "sh", "dash",
                                  "tcsh", "csh", "nu", "elvish"]
    guard !bareNames.contains(pathString.lowercased()) else { return nil }
    guard pathString.hasPrefix("/") || pathString.hasPrefix("~") else {
        // Doesn't look like a path — treat the whole thing as a name.
        return pathString.isEmpty ? nil : ProjectRef(name: pathString)
    }

    // Derive name from the last path component.
    let url = URL(fileURLWithPath: pathString.replacingOccurrences(of: "~", with: "/Users/user"))
    let lastComponent = url.lastPathComponent
    guard !lastComponent.isEmpty, lastComponent != "/" else { return nil }

    return ProjectRef(name: lastComponent, path: pathString)
}
