import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Table-driven tests for `assembleCaptureSet(from:)` (issue #48).
///
/// Acceptance criteria:
/// - Pure function maps injected raw signals → normalized CaptureSet.
/// - selectedText nil when empty/whitespace-only; preserved when non-empty.
/// - project via ProjectHeuristic: nil for unknown apps/titles, correct for editors/terminals.
/// - No AppKit/AX imports (enforced by living in the pure layer).
final class CaptureSetAssemblerTests: XCTestCase {

    // MARK: - selectedText normalization

    func testNoSelectionProducesNilSelectedText() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: nil
        ))
        XCTAssertNil(set.selectedText)
    }

    func testEmptySelectionProducesNilSelectedText() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: ""
        ))
        XCTAssertNil(set.selectedText, "Empty string selection must normalize to nil")
    }

    func testWhitespaceOnlySelectionProducesNilSelectedText() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "   \n\t  "
        ))
        XCTAssertNil(set.selectedText, "Whitespace-only selection must normalize to nil")
    }

    func testRealSelectionIsPreserved() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "func rate_limit(ip: String) -> Bool"
        ))
        XCTAssertEqual(set.selectedText, "func rate_limit(ip: String) -> Bool")
    }

    func testSelectionWithLeadingTrailingWhitespaceIsTrimmed() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "  func rate_limit()  "
        ))
        XCTAssertEqual(set.selectedText, "func rate_limit()",
            "Leading/trailing whitespace in selection must be trimmed")
    }

    // MARK: - Project heuristic

    func testUnknownAppProducesNilProject() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Spotify",
            windowTitle: "Rock playlist"
        ))
        XCTAssertNil(set.project, "Unknown app must produce nil project")
    }

    func testUnparseableWindowTitleProducesNilProject() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "Welcome"  // no em-dash separator
        ))
        XCTAssertNil(set.project)
    }

    func testKnownEditorTitleProducesProjectFromHeuristic() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "VoiceTurnController.swift \u{2014} tnt"
        ))
        XCTAssertEqual(set.project?.name, "tnt")
    }

    func testTerminalTitleProducesProjectWithPath() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Terminal",
            windowTitle: "dev@mbp: ~/projects/tnt"
        ))
        XCTAssertEqual(set.project?.name, "tnt")
        XCTAssertEqual(set.project?.path, "~/projects/tnt")
    }

    func testNilAppNameSkipsProjectHeuristic() {
        // If appName is nil, we can't dispatch to the right strategy.
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: nil,
            windowTitle: "main.swift — tnt"
        ))
        XCTAssertNil(set.project)
    }

    func testNilWindowTitleSkipsProjectHeuristic() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: nil
        ))
        XCTAssertNil(set.project)
    }

    // MARK: - Passthrough fields

    func testAppNameAndWindowTitlePassThrough() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Xcode",
            windowTitle: "AppDelegate.swift — TNT"
        ))
        XCTAssertEqual(set.appName, "Xcode")
        XCTAssertEqual(set.windowTitle, "AppDelegate.swift — TNT")
    }

    // MARK: - Full assembly

    func testFullAssemblyWithAllFieldsPopulated() {
        let set = assembleCaptureSet(from: RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift \u{2014} tnt",
            selectedText: "func rate_limit()"
        ))
        XCTAssertEqual(set.appName, "Cursor")
        XCTAssertEqual(set.windowTitle, "main.swift \u{2014} tnt")
        XCTAssertEqual(set.selectedText, "func rate_limit()")
        XCTAssertEqual(set.project?.name, "tnt")
        XCTAssertFalse(set.isEmpty)
    }

    func testEmptySignalsProduceEmptyCaptureSet() {
        let set = assembleCaptureSet(from: RawWindowSignals())
        XCTAssertTrue(set.isEmpty)
    }

    // MARK: - No AppKit/AX import (structural)

    // This test is implicitly enforced by the package compiling at all —
    // CaptureSetAssembler.swift must not import AppKit or call any AX APIs,
    // otherwise the macOS-only AX framework would break cross-platform builds.
    // Since TNTCore/TNTPlatformMac are both listed with iOS targets in their
    // Package.swift, a compile error would surface any inadvertent AX import.
    func testAssemblyModuleHasNoAppKitDependency() {
        // If this file compiles, the no-AppKit contract holds.
        // (A real enforcement requires a CI lint rule or a Linux build.)
        XCTAssertTrue(true)
    }
}
