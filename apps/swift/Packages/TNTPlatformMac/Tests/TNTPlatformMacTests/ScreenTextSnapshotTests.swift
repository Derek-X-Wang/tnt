import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Golden tests for `ScreenTextSnapshot` and `ScreenTextSnapshotBuilder` (issue #100).
///
/// Acceptance criteria:
/// - Populated snapshot golden JSON shape.
/// - Head+tail truncation with correct counts.
/// - Multi-source ordering (armed order preserved).
/// - Empty-text snapshot shape (valid, not an error).
/// - `visionAvailable: true / false` branches both built.
/// - Total budget enforced; no source silently dropped.
/// - Pure: no AppKit/AX imports; `swift test` green for TNTPlatformMac.
final class ScreenTextSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func makeAppshot(
        windowText: String?,
        appName: String = "TestApp",
        windowTitle: String = "Test Window"
    ) -> Appshot {
        Appshot(windowText: windowText, appName: appName, windowTitle: windowTitle)
    }

    // MARK: - Populated snapshot golden shape

    func testPopulatedSnapshotHasCorrectKindAndVersion() {
        let appshot = makeAppshot(windowText: "func foo() { return 42 }")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what does this function do?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.kind, "screen_text_snapshot")
        XCTAssertEqual(snapshot.version, 1)
    }

    func testPopulatedSnapshotPreservesQuestion() {
        let appshot = makeAppshot(windowText: "hello world")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what does this say?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.question, "what does this say?")
    }

    func testPopulatedSnapshotHasOneSource() {
        let appshot = makeAppshot(windowText: "import Foundation\nlet x = 1")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what is this?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 1)
    }

    func testPopulatedSnapshotSourceHasCorrectFields() {
        let text = "func greet() { print(\"Hello\") }"
        let appshot = makeAppshot(windowText: text, appName: "Xcode", windowTitle: "main.swift")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what does greet do?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let source = snapshot.sources[0]
        XCTAssertEqual(source.appName, "Xcode")
        XCTAssertEqual(source.windowTitle, "main.swift")
        XCTAssertEqual(source.source, .armedAppshot)
        XCTAssertEqual(source.text, text)
        XCTAssertEqual(source.originalCharCount, text.count)
        XCTAssertEqual(source.returnedCharCount, text.count)
        XCTAssertFalse(source.truncated)
        XCTAssertEqual(source.textQuality, .ok)
    }

    // MARK: - JSON serialization

    func testSnapshotProducesValidJSON() throws {
        let appshot = makeAppshot(windowText: "error: use of undeclared identifier 'foo'")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what is this error?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let jsonStr = try snapshot.jsonString()
        let data = Data(jsonStr.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(obj?["kind"] as? String, "screen_text_snapshot")
        XCTAssertEqual(obj?["version"] as? Int, 1)
        XCTAssertEqual(obj?["question"] as? String, "what is this error?")
        XCTAssertFalse(obj?["fullVisionAvailable"] as? Bool ?? true)
        XCTAssertNotNil(obj?["sources"])
        XCTAssertNotNil(obj?["instruction"])
    }

    func testSnapshotJSONIsStableForIdenticalInputs() throws {
        let appshot = makeAppshot(windowText: "stable text here")
        let s1 = ScreenTextSnapshotBuilder.build(
            question: "what?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let s2 = ScreenTextSnapshotBuilder.build(
            question: "what?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(try s1.jsonString(), try s2.jsonString(),
            "Identical inputs must produce byte-identical JSON")
    }

    // MARK: - Truncation: head+tail with correct counts

    func testTruncationProducesCorrectOriginalCount() {
        // Text longer than the per-source budget (budget = 8000 / 1 = 8000)
        // Use a budget override by stacking many appshots to force small budget.
        // To test truncation, build a custom snapshot source directly.
        let longText = String(repeating: "a", count: 10_000)
        let appshot = makeAppshot(windowText: longText, appName: "Editor", windowTitle: "big.swift")

        // With 1 appshot, budget = 8000. The text is 10000 chars > 8000, so truncation happens.
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what is this?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let source = snapshot.sources[0]
        XCTAssertEqual(source.originalCharCount, 10_000)
        XCTAssertLessThan(source.returnedCharCount, 10_000)
        XCTAssertTrue(source.truncated)
    }

    func testTruncationPreservesHeadAndTail() {
        // 10,000 chars of text: first char is 'S', last char is 'E'.
        var longText = String(repeating: "M", count: 9_998)
        longText = "S" + longText + "E"
        XCTAssertEqual(longText.count, 10_000)

        let appshot = makeAppshot(windowText: longText)
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what?",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let source = snapshot.sources[0]
        XCTAssertTrue(source.text.hasPrefix("S"), "Head must be preserved")
        XCTAssertTrue(source.text.hasSuffix("E"), "Tail must be preserved")
        XCTAssertTrue(source.text.contains("[truncated]"), "Elision marker must be present")
    }

    func testReturnedCharCountMatchesActualTextLength() {
        let longText = String(repeating: "x", count: 10_000)
        let appshot = makeAppshot(windowText: longText)
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .freshGrab,
            visionAvailable: false
        )
        let source = snapshot.sources[0]
        XCTAssertEqual(source.returnedCharCount, source.text.count,
            "returnedCharCount must equal the actual text length")
    }

    // MARK: - Multi-source ordering (armed order preserved)

    func testMultiSourceOrderingPreserved() {
        let a1 = Appshot(windowText: "first appshot", appName: "Cursor", windowTitle: "file.swift")
        let a2 = Appshot(windowText: "second appshot", appName: "Chrome", windowTitle: "localhost")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what is on screen?",
            appshots: [a1, a2],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 2)
        XCTAssertEqual(snapshot.sources[0].appName, "Cursor")
        XCTAssertEqual(snapshot.sources[1].appName, "Chrome")
    }

    func testMultiSourceBudgetDistributed() {
        // 3 sources; each gets totalBudget/3 = 2666 chars budget.
        // Each appshot has 10,000 chars — all should be truncated.
        let longText = String(repeating: "x", count: 10_000)
        let appshots = (0..<3).map { i in
            Appshot(windowText: longText, appName: "App\(i)", windowTitle: "title\(i)")
        }
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: appshots,
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 3)
        for source in snapshot.sources {
            XCTAssertTrue(source.truncated, "Each source should be truncated when text exceeds budget")
            XCTAssertEqual(source.originalCharCount, 10_000)
        }
    }

    func testNoSourceSilentlyDropped() {
        // 100 sources with very long text — all should appear even if budget is tiny per source.
        let longText = String(repeating: "z", count: 10_000)
        let appshots = (0..<100).map { i in
            Appshot(windowText: longText, appName: "App\(i)", windowTitle: "t\(i)")
        }
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: appshots,
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 100,
            "No source must be silently dropped — all 100 must appear")
    }

    // MARK: - Empty text snapshot

    func testEmptyTextProducesValidSnapshot() {
        let appshot = makeAppshot(windowText: "")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what's here?",
            appshots: [appshot],
            sourceKind: .freshGrab,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources[0].textQuality, .empty)
        XCTAssertEqual(snapshot.sources[0].originalCharCount, 0)
        XCTAssertEqual(snapshot.sources[0].returnedCharCount, 0)
        XCTAssertFalse(snapshot.sources[0].truncated)
    }

    func testNilWindowTextProducesEmptyQualitySource() {
        let appshot = makeAppshot(windowText: nil)
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources[0].textQuality, .empty)
    }

    func testEmptyAppshotsProducesEmptySourcesArray() {
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [],
            sourceKind: .freshGrab,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources.count, 0)
    }

    // MARK: - visionAvailable branches

    func testVisionAvailableFalseHasNoEscalationInstruction() {
        let appshot = makeAppshot(windowText: "some text")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertFalse(snapshot.fullVisionAvailable)
        XCTAssertFalse(snapshot.instruction.contains("analyze_screen"),
            "M4a: no escalation to analyze_screen in instruction when visionAvailable=false")
    }

    func testVisionAvailableTrueHasEscalationInstruction() {
        let appshot = makeAppshot(windowText: "some text")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: true
        )
        XCTAssertTrue(snapshot.fullVisionAvailable)
        XCTAssertTrue(snapshot.instruction.contains("analyze_screen"),
            "M4b path: instruction must reference analyze_screen when visionAvailable=true")
    }

    // MARK: - Source kind

    func testFreshGrabSourceKindEncoded() throws {
        let appshot = makeAppshot(windowText: "fresh content")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .freshGrab,
            visionAvailable: false
        )
        let json = try snapshot.jsonString()
        XCTAssertTrue(json.contains("fresh_grab"),
            "fresh_grab source kind must appear in JSON")
    }

    func testArmedAppshotSourceKindEncoded() throws {
        let appshot = makeAppshot(windowText: "armed content")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        let json = try snapshot.jsonString()
        XCTAssertTrue(json.contains("armed_appshot"),
            "armed_appshot source kind must appear in JSON")
    }

    // MARK: - Text quality

    func testShortTextProducesSparseQuality() {
        let appshot = makeAppshot(windowText: "hi")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources[0].textQuality, .sparse)
    }

    func testSubstantialTextProducesOkQuality() {
        let appshot = makeAppshot(windowText: String(repeating: "a", count: 100))
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q",
            appshots: [appshot],
            sourceKind: .armedAppshot,
            visionAvailable: false
        )
        XCTAssertEqual(snapshot.sources[0].textQuality, .ok)
    }

    // MARK: - Pure: no AppKit/AX imports (compile-time guarantee — no import needed here)
}
