import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Tests for the Appshot extensions to `CaptureChipViewModel` (issue #102, M4a).
///
/// Acceptance criteria:
/// - Summary for 0/1/2+ appshots (distinct + duplicate source apps), composing
///   with scalar fields.
/// - Appshot-only set: `isEmpty == false`, summary shows 📸 state.
/// - Preview rows expose app/title/snippet/hasImage per appshot, in armed order.
/// - `clearLast` removes newest only; `clear` empties; both leave scalar fields per contract.
/// - Pure (no SwiftUI/AppKit).
final class CaptureChipViewModelAppshotTests: XCTestCase {

    // MARK: - Helpers

    private func makeAppshot(
        appName: String,
        windowTitle: String = "Window",
        windowText: String? = "some text here that is long enough to be ok quality"
    ) -> Appshot {
        Appshot(windowText: windowText, appName: appName, windowTitle: windowTitle)
    }

    private func captureWithAppshots(_ appshots: [Appshot]) -> CaptureSet {
        CaptureSet(appshots: appshots)
    }

    private func captureWithAppshotsAndScalar(_ appshots: [Appshot]) -> CaptureSet {
        CaptureSet(
            appName: "Xcode",
            windowTitle: "main.swift",
            selectedText: "let x = 1",
            project: ProjectRef(name: "tnt", path: "/tnt"),
            appshots: appshots
        )
    }

    // MARK: - Summary: 0 appshots (scalar only)

    func testZeroAppshotsScalarOnlySummary() {
        let capture = CaptureSet(appName: "Cursor", selectedText: "func foo() {}")
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertFalse(vm.summary.contains("📸"),
            "Zero appshots must not include 📸 in summary")
        XCTAssertTrue(vm.summary.contains("Cursor"))
    }

    // MARK: - Summary: 1 appshot

    func testOneAppshotSummaryShowsCountAndApp() {
        let appshot = makeAppshot(appName: "Cursor")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        XCTAssertTrue(vm.summary.contains("📸"),
            "One appshot must include 📸 emoji")
        XCTAssertTrue(vm.summary.contains("×1"),
            "One appshot must show ×1 count")
        XCTAssertTrue(vm.summary.contains("Cursor"),
            "One appshot must show source app name")
    }

    // MARK: - Summary: 2+ appshots distinct apps

    func testTwoDistinctAppshotsSummary() {
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([a1, a2]))
        XCTAssertTrue(vm.summary.contains("×2"))
        XCTAssertTrue(vm.summary.contains("Cursor"))
        XCTAssertTrue(vm.summary.contains("Chrome"))
    }

    func testTwoDuplicateAppshotsSummary() {
        // Two Cursor appshots — the summary shows both (not deduplicated here)
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Cursor")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([a1, a2]))
        XCTAssertTrue(vm.summary.contains("×2"),
            "Count must reflect both even if same app name")
        XCTAssertTrue(vm.summary.contains("Cursor"))
    }

    // MARK: - Summary: appshots compose with scalar fields

    func testAppshotsSummaryComposesWithSelectedTextCount() {
        let appshot = makeAppshot(appName: "Cursor")
        let capture = CaptureSet(
            selectedText: "let x = 1",
            appshots: [appshot]
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("📸"),
            "Appshot summary must still appear with scalar text")
        XCTAssertTrue(vm.summary.contains("chars"),
            "Selected-text char count must compose alongside appshot summary")
    }

    func testAppshotsSummaryComposesWithProjectName() {
        let appshot = makeAppshot(appName: "Cursor")
        let capture = CaptureSet(
            project: ProjectRef(name: "tnt", path: "/tnt"),
            appshots: [appshot]
        )
        let vm = CaptureChipViewModel(capture: capture)
        XCTAssertTrue(vm.summary.contains("📸"))
        XCTAssertTrue(vm.summary.contains("tnt"),
            "Project name must compose alongside appshot summary")
    }

    // MARK: - Appshot-only: isEmpty == false

    func testAppshotOnlySetIsNotEmpty() {
        let appshot = makeAppshot(appName: "Xcode")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        XCTAssertFalse(vm.isEmpty,
            "Appshot-only CaptureSet must NOT be empty — ADR-0004 visibility")
    }

    func testAppshotOnlySummaryIsNotNoContext() {
        let appshot = makeAppshot(appName: "Xcode")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        XCTAssertNotEqual(vm.summary, "No context",
            "Appshot-only state must not show 'No context'")
        XCTAssertTrue(vm.summary.contains("📸"),
            "Appshot-only summary must show 📸")
    }

    // MARK: - Preview rows

    func testPreviewRowsAreEmptyWithNoAppshots() {
        let vm = CaptureChipViewModel(capture: CaptureSet(appName: "Cursor"))
        XCTAssertTrue(vm.appshotPreviewRows.isEmpty)
    }

    func testPreviewRowsExposeAppAndTitle() {
        let appshot = Appshot(windowText: "import Foundation", appName: "Xcode", windowTitle: "App.swift")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        let rows = vm.appshotPreviewRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].appName, "Xcode")
        XCTAssertEqual(rows[0].windowTitle, "App.swift")
    }

    func testPreviewRowsExposeWindowTextSnippet() {
        let longText = String(repeating: "x", count: 200)
        let appshot = Appshot(windowText: longText, appName: "Editor", windowTitle: "big.txt")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        let row = vm.appshotPreviewRows[0]
        XCTAssertFalse(row.windowTextSnippet.isEmpty,
            "Window text snippet must not be empty when window text exists")
        XCTAssertLessThanOrEqual(
            row.windowTextSnippet.count,
            200,
            "Snippet must be shorter than full text"
        )
    }

    func testPreviewRowsHasImageFalseInM4a() {
        let appshot = makeAppshot(appName: "Cursor")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        XCTAssertFalse(vm.appshotPreviewRows[0].hasImage,
            "hasImage must be false in M4a — image tier arrives in M4b")
    }

    func testPreviewRowsAreInArmedOrder() {
        let a1 = Appshot(windowText: "first", appName: "App1", windowTitle: "t1")
        let a2 = Appshot(windowText: "second", appName: "App2", windowTitle: "t2")
        let a3 = Appshot(windowText: "third", appName: "App3", windowTitle: "t3")
        let vm = CaptureChipViewModel(capture: captureWithAppshots([a1, a2, a3]))
        let rows = vm.appshotPreviewRows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].appName, "App1")
        XCTAssertEqual(rows[1].appName, "App2")
        XCTAssertEqual(rows[2].appName, "App3")
    }

    // MARK: - clearLast

    func testClearLastRemovesNewest() {
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        var vm = CaptureChipViewModel(capture: captureWithAppshots([a1, a2]))
        vm.clearLast()
        XCTAssertEqual(vm.appshotPreviewRows.count, 1,
            "clearLast must leave one appshot remaining")
        XCTAssertEqual(vm.appshotPreviewRows[0].appName, "Cursor",
            "clearLast must remove the NEWEST (last) appshot — Cursor stays")
    }

    func testClearLastOnSingleAppshotLeavesEmptySet() {
        let appshot = makeAppshot(appName: "Cursor")
        var vm = CaptureChipViewModel(capture: captureWithAppshots([appshot]))
        vm.clearLast()
        XCTAssertTrue(vm.appshotPreviewRows.isEmpty)
        XCTAssertTrue(vm.isEmpty)
    }

    func testClearLastPreservesScalarFields() {
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        let capture = CaptureSet(
            appName: "Xcode",
            selectedText: "let x = 1",
            project: ProjectRef(name: "tnt", path: "/tnt"),
            appshots: [a1, a2]
        )
        var vm = CaptureChipViewModel(capture: capture)
        vm.clearLast()
        // Scalar fields must survive clearLast
        XCTAssertTrue(vm.summary.contains("Xcode") || vm.summary.contains("Cursor"),
            "Scalar app info must persist after clearLast")
        // The removed appshot (Chrome) should not appear in preview rows
        XCTAssertFalse(vm.appshotPreviewRows.contains(where: { $0.appName == "Chrome" }),
            "Chrome (newest) must be removed by clearLast")
    }

    func testClearLastOnEmptyIsNoOp() {
        var vm = CaptureChipViewModel(capture: .empty)
        vm.clearLast()  // must not crash
        XCTAssertTrue(vm.isEmpty)
    }

    // MARK: - clear

    func testClearRemovesAllIncludingAppshots() {
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        var vm = CaptureChipViewModel(capture: captureWithAppshotsAndScalar([a1, a2]))
        vm.clear()
        XCTAssertTrue(vm.isEmpty)
        XCTAssertEqual(vm.summary, "No context")
        XCTAssertTrue(vm.appshotPreviewRows.isEmpty)
    }

    // MARK: - Existing scalar tests still pass (regression)

    func testExistingCaptureSetWithOnlyAppNameNotEmpty() {
        let vm = CaptureChipViewModel(capture: CaptureSet(appName: "Safari"))
        XCTAssertFalse(vm.isEmpty)
        XCTAssertTrue(vm.summary.contains("Safari"))
    }

    func testExistingClearTransitionsToEmptyState() {
        var vm = CaptureChipViewModel(capture: CaptureSet(appName: "Cursor", selectedText: "let x = 1"))
        XCTAssertFalse(vm.isEmpty)
        vm.clear()
        XCTAssertTrue(vm.isEmpty)
    }
}
