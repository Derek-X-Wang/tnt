import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Unit tests for `CaptureChipViewModel` (issue #81).
///
/// Acceptance criteria:
/// - A populated CaptureSet (app + selected text + project) yields a summary
///   with the app label, selected-text char count, and project name.
/// - CaptureSet.empty yields the empty/paused state string.
/// - The clear action transitions the summary to the empty state.
/// - View-model is pure (no SwiftUI/AppKit); unit tests in TNTPlatformMacTests.
final class CaptureChipViewModelTests: XCTestCase {

    // MARK: - Populated CaptureSet

    func testPopulatedCaptureSetShowsAppName() {
        let capture = CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "func greet() {}",
            project: ProjectRef(name: "tnt", path: "/path/tnt")
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("Cursor"),
            "Summary must include the app name")
    }

    func testPopulatedCaptureSetShowsSelectedTextCharCount() {
        let selectedText = "func greet() {}"  // 16 chars
        let capture = CaptureSet(
            appName: "Xcode",
            windowTitle: "Foo.swift",
            selectedText: selectedText,
            project: nil
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("\(selectedText.count)"),
            "Summary must include the selected-text char count (\(selectedText.count))")
    }

    func testPopulatedCaptureSetShowsProjectName() {
        let capture = CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "let x = 1",
            project: ProjectRef(name: "tnt", path: "/path/tnt")
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("tnt"),
            "Summary must include the project name")
    }

    func testPopulatedCaptureSetIsNotEmpty() {
        let capture = CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "code",
            project: nil
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertFalse(vm.isEmpty, "A populated CaptureSet must not produce isEmpty=true")
    }

    // MARK: - Empty CaptureSet

    func testEmptyCaptureSetProducesEmptyState() {
        let vm = CaptureChipViewModel(capture: .empty)
        XCTAssertTrue(vm.isEmpty, "CaptureSet.empty must produce isEmpty=true")
    }

    func testEmptyCaptureSetSummaryIsNonEmpty() {
        // The empty/paused state still has a display string (e.g. "No context")
        let vm = CaptureChipViewModel(capture: .empty)
        XCTAssertFalse(vm.summary.isEmpty,
            "Empty state must still provide a non-empty summary string for the Capture Chip")
    }

    // MARK: - Clear action

    func testClearActionTransitionsToEmptyState() {
        var vm = CaptureChipViewModel(capture: CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift",
            selectedText: "let x = 1",
            project: nil
        ))
        XCTAssertFalse(vm.isEmpty, "Should start non-empty")
        vm.clear()
        XCTAssertTrue(vm.isEmpty, "After clear(), view-model must report isEmpty=true")
    }

    func testClearActionUpdatesDisplaySummary() {
        var vm = CaptureChipViewModel(capture: CaptureSet(
            appName: "Xcode",
            windowTitle: "AppDelegate.swift",
            selectedText: "class AppDelegate {}",
            project: nil
        ))
        let beforeClear = vm.summary
        vm.clear()
        let afterClear = vm.summary
        // The summary must change after clearing
        XCTAssertNotEqual(beforeClear, afterClear,
            "Clearing must update the summary string")
        // And it must match the empty-state summary
        let emptyVM = CaptureChipViewModel(capture: .empty)
        XCTAssertEqual(afterClear, emptyVM.summary,
            "After clear(), summary must match the empty CaptureSet's summary")
    }

    // MARK: - App-only CaptureSet (no selected text)

    func testCaptureSetWithOnlyAppNameDoesNotShowCharCount() {
        let capture = CaptureSet(
            appName: "Safari",
            windowTitle: "Apple - Start",
            selectedText: nil,
            project: nil
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("Safari"))
        XCTAssertFalse(vm.isEmpty)
    }

    // MARK: - Pure: no SwiftUI/AppKit references needed
    // (compile-time guarantee — the test target does not import SwiftUI/AppKit)
}
