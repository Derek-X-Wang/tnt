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
}
