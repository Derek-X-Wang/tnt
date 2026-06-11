import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Table-driven tests for `projectRef(appName:windowTitle:)`.
///
/// Acceptance criteria (issue #31):
/// - ≥2 cases per app family (VS Code/Cursor, JetBrains, Terminal/iTerm2).
/// - Editor noise markers (●, Workspace, [Administrator]) stripped.
/// - Unknown/unparseable titles return nil (no crash).
/// - Terminal titles yield a path where one is present.
final class ProjectHeuristicTests: XCTestCase {

    // MARK: - VS Code / Cursor

    func testCursorSimpleTitle() {
        // "VoiceTurnController.swift — tnt"
        let ref = projectRef(
            appName: "Cursor",
            windowTitle: "VoiceTurnController.swift \u{2014} tnt"
        )
        XCTAssertEqual(ref?.name, "tnt")
        XCTAssertNil(ref?.path)
    }

    func testCursorWithUnsavedMarker() {
        // "● main.swift — tnt"
        let ref = projectRef(
            appName: "Cursor",
            windowTitle: "● main.swift \u{2014} tnt"
        )
        XCTAssertEqual(ref?.name, "tnt")
    }

    func testCursorWithWorkspaceSuffix() {
        // "file.swift — tnt — Workspace" → strip "— Workspace"
        let ref = projectRef(
            appName: "Cursor",
            windowTitle: "file.swift \u{2014} tnt \u{2014} Workspace"
        )
        // tnt is the second segment; "— Workspace" is the third
        XCTAssertEqual(ref?.name, "tnt")
    }

    func testCodeNoProjectInTitle() {
        // "Welcome" has no separator → nil
        let ref = projectRef(appName: "Code", windowTitle: "Welcome")
        XCTAssertNil(ref, "No em-dash separator means no project name — should return nil")
    }

    func testCodeWithMultiWordProjectName() {
        // "App.tsx — my-app"
        let ref = projectRef(
            appName: "Code",
            windowTitle: "App.tsx \u{2014} my-app"
        )
        XCTAssertEqual(ref?.name, "my-app")
    }

    func testCursorWithBulletMarker() {
        // "• Package.swift — tnt" (bullet variant of unsaved marker)
        let ref = projectRef(
            appName: "Cursor",
            windowTitle: "• Package.swift \u{2014} tnt"
        )
        XCTAssertEqual(ref?.name, "tnt")
    }

    // MARK: - JetBrains

    func testIntelliJSimpleTitle() {
        // "tnt – src/Main.kt" (en-dash)
        let ref = projectRef(
            appName: "IntelliJ IDEA",
            windowTitle: "tnt \u{2013} src/Main.kt"
        )
        XCTAssertEqual(ref?.name, "tnt")
        XCTAssertNil(ref?.path)
    }

    func testPyCharmTitle() {
        // "myapp – app/models.py"
        let ref = projectRef(
            appName: "PyCharm",
            windowTitle: "myapp \u{2013} app/models.py"
        )
        XCTAssertEqual(ref?.name, "myapp")
    }

    func testJetBrainsNoSeparator() {
        // Just the project name — still valid
        let ref = projectRef(appName: "GoLand", windowTitle: "tnt")
        XCTAssertEqual(ref?.name, "tnt")
    }

    func testWebStormTitle() {
        // "frontend-app – components/Header.tsx"
        let ref = projectRef(
            appName: "WebStorm",
            windowTitle: "frontend-app \u{2013} components/Header.tsx"
        )
        XCTAssertEqual(ref?.name, "frontend-app")
    }

    // MARK: - Terminal / iTerm2

    func testTerminalUserAtHostPath() {
        // "dev@mbp: ~/projects/tnt"
        let ref = projectRef(
            appName: "Terminal",
            windowTitle: "dev@mbp: ~/projects/tnt"
        )
        XCTAssertEqual(ref?.name, "tnt")
        XCTAssertEqual(ref?.path, "~/projects/tnt")
    }

    func testTerminalTildeOnlyPath() {
        // "~/projects/myapp"
        let ref = projectRef(appName: "Terminal", windowTitle: "~/projects/myapp")
        XCTAssertEqual(ref?.name, "myapp")
        XCTAssertEqual(ref?.path, "~/projects/myapp")
    }

    func testTerminalAbsolutePath() {
        // "/Users/dev/work/tnt"
        let ref = projectRef(appName: "iTerm2", windowTitle: "/Users/dev/work/tnt")
        XCTAssertEqual(ref?.name, "tnt")
        XCTAssertEqual(ref?.path, "/Users/dev/work/tnt")
    }

    func testTerminalBareShellName() {
        // Just "bash" → nil (no project)
        let ref = projectRef(appName: "Terminal", windowTitle: "bash")
        XCTAssertNil(ref)
    }

    func testTerminalZsh() {
        let ref = projectRef(appName: "Terminal", windowTitle: "zsh")
        XCTAssertNil(ref)
    }

    func testWarpTerminal() {
        // "warp" app, path title
        let ref = projectRef(appName: "Warp", windowTitle: "~/code/tnt")
        XCTAssertEqual(ref?.name, "tnt")
    }

    // MARK: - Unknown app / unparseable

    func testUnknownAppReturnsNil() {
        let ref = projectRef(appName: "Spotify", windowTitle: "Rock music")
        XCTAssertNil(ref, "Unknown app must return nil")
    }

    func testSafariReturnsNil() {
        let ref = projectRef(appName: "Safari", windowTitle: "GitHub — tnt")
        XCTAssertNil(ref, "Safari is not a known editor/terminal app")
    }

    func testEmptyWindowTitleReturnsNil() {
        let ref = projectRef(appName: "Cursor", windowTitle: "")
        XCTAssertNil(ref)
    }

    func testWhitespaceOnlyWindowTitleReturnsNil() {
        let ref = projectRef(appName: "Cursor", windowTitle: "   ")
        XCTAssertNil(ref)
    }

    // MARK: - Issue #68: ~ over-replace fix

    /// A terminal path with an embedded ~ (not a leading one) must NOT
    /// have the ~ expanded globally. The old code replaced every ~ with
    /// "/Users/user", producing a corrupted path.
    ///
    ///   "/Users/dev/repo~backup" → name should be "repo~backup"
    ///   Old code: URL("/Users/user/Users/user/repo/Users/user/backup").lastPathComponent
    ///             = "backup" or garbled — wrong.
    ///   New code: URL("/Users/dev/repo~backup").lastPathComponent = "repo~backup" — correct.
    func testTerminalEmbeddedTildeNotExpanded() {
        let ref = projectRef(
            appName: "Terminal",
            windowTitle: "/Users/dev/repo~backup"
        )
        XCTAssertEqual(ref?.name, "repo~backup",
            "Embedded ~ must not be expanded; lastPathComponent should be repo~backup")
    }

    /// A leading ~/path must still expand correctly (leading ~ is valid home shorthand).
    func testTerminalLeadingTildeStillYieldsCorrectName() {
        let ref = projectRef(
            appName: "Terminal",
            windowTitle: "~/projects/tnt"
        )
        XCTAssertEqual(ref?.name, "tnt",
            "Leading ~ must still produce the correct last path component")
        XCTAssertEqual(ref?.path, "~/projects/tnt")
    }

    /// Embedded ~ in a path with user@host prefix is also preserved.
    func testTerminalUserAtHostWithEmbeddedTildeInPath() {
        let ref = projectRef(
            appName: "Terminal",
            windowTitle: "dev@host: /Users/dev/repo~backup"
        )
        XCTAssertEqual(ref?.name, "repo~backup",
            "Embedded ~ after user@host strip must not be expanded")
    }

    // MARK: - Zed (issue #94, corrected by issue #117)

    /// Observed live: Zed window title format is `{project} — {filename}` (U+2014
    /// em-dash). The project is the FIRST segment (not the second as #94 assumed).
    /// The heuristic prefers the segment that does NOT look like a filename
    /// (no leading dot, no file extension), making it robust to either order.
    ///
    ///   `"tnt — main.swift"` → name = "tnt"
    func testZedSimpleTitle() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: "tnt \u{2014} main.swift"
        )
        XCTAssertEqual(ref?.name, "tnt")
        XCTAssertNil(ref?.path)
    }

    /// Zed with a multi-word / hyphenated project name.
    ///
    ///   `"my-frontend — App.tsx"` → name = "my-frontend"
    func testZedHyphenatedProjectName() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: "my-frontend \u{2014} App.tsx"
        )
        XCTAssertEqual(ref?.name, "my-frontend")
    }

    /// Verbatim observed case from #117: `kitcn — .mcp.json`.
    /// `.mcp.json` is a dotfile (leading dot) → not the project.
    /// `kitcn` has no extension and no leading dot → is the project.
    func testZedKitcnDotfileMcpJson() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: "kitcn \u{2014} .mcp.json"
        )
        XCTAssertEqual(ref?.name, "kitcn",
            "kitcn — .mcp.json: project must be kitcn, not the dotfile .mcp.json")
        XCTAssertNil(ref?.path)
    }

    /// Dotfile in first position, project in second — heuristic must still
    /// pick the non-filename segment regardless of order.
    ///
    ///   `".mcp.json — kitcn"` → name = "kitcn"
    func testZedDotfileFirstProjectSecond() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: ".mcp.json \u{2014} kitcn"
        )
        XCTAssertEqual(ref?.name, "kitcn",
            ".mcp.json — kitcn: dotfile in first position must not be chosen as project")
    }

    /// Extension-bearing filename in second position (project first).
    ///
    ///   `"tnt — README.md"` → name = "tnt"
    func testZedProjectFirstExtensionFilenameSecond() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: "tnt \u{2014} README.md"
        )
        XCTAssertEqual(ref?.name, "tnt")
    }

    /// When both segments look like plain names (no extension, no leading dot),
    /// prefer the first segment — matches observed current Zed layout where
    /// the project is always first.
    func testZedBothSegmentsLookLikeNames() {
        let ref = projectRef(
            appName: "Zed",
            windowTitle: "tnt \u{2014} main"
        )
        XCTAssertEqual(ref?.name, "tnt",
            "When both segments have no extension/dot, first segment wins")
    }

    /// Zed welcome screen / no project open — title is just "Zed" with no
    /// em-dash separator, so no project can be derived.
    func testZedWelcomeScreenNoProject() {
        let ref = projectRef(appName: "Zed", windowTitle: "Zed")
        XCTAssertNil(ref, "No em-dash separator in Zed welcome title — should return nil")
    }

    /// Zed with an untitled buffer has no file or project separator — should
    /// return nil gracefully.
    func testZedUntitledBufferReturnsNil() {
        let ref = projectRef(appName: "Zed", windowTitle: "untitled")
        XCTAssertNil(ref, "Untitled Zed buffer with no project separator must return nil")
    }

    /// Case-insensitive detection: "zed" lowercase matches the Zed app family.
    func testZedLowercaseAppName() {
        let ref = projectRef(
            appName: "zed",
            windowTitle: "docs-project \u{2014} README.md"
        )
        XCTAssertEqual(ref?.name, "docs-project")
    }
}
