import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Golden tests for `ScreenTextSnapshot` and `ScreenTextSnapshotBuilder`
/// (issue #100; mixed-mode + capture-age semantics per #119).
///
/// Acceptance criteria:
/// - Populated snapshot golden JSON shape (version 2).
/// - Head+tail truncation with correct counts.
/// - Mixed-source ordering: armed first (arm order), current last, per-source kinds.
/// - `capturedSecondsAgo` from injected `now`; nil without `capturedAt`.
/// - Empty-text snapshot shape (valid, not an error).
/// - `visionAvailable: true / false` branches both built.
/// - Total budget enforced across armed+current; no source silently dropped.
/// - Pure: no AppKit/AX imports; `swift test` green for TNTPlatformMac.
final class ScreenTextSnapshotTests: XCTestCase {

    // MARK: - Helpers

    /// Fixed reference instant so age math is deterministic.
    private let refNow = Date(timeIntervalSince1970: 1_000_000)

    private func makeAppshot(
        windowText: String?,
        appName: String = "TestApp",
        windowTitle: String = "Test Window",
        capturedAt: Date? = nil
    ) -> Appshot {
        Appshot(windowText: windowText, appName: appName, windowTitle: windowTitle, capturedAt: capturedAt)
    }

    private func buildArmed(
        question: String? = "q",
        _ appshots: [Appshot],
        visionAvailable: Bool = false
    ) -> ScreenTextSnapshot {
        ScreenTextSnapshotBuilder.build(
            question: question,
            armed: appshots,
            current: nil,
            visionAvailable: visionAvailable,
            now: refNow
        )
    }

    // MARK: - Populated snapshot golden shape

    func testPopulatedSnapshotHasCorrectKindAndVersion() {
        let snapshot = buildArmed([makeAppshot(windowText: "func foo() { return 42 }")])
        XCTAssertEqual(snapshot.kind, "screen_text_snapshot")
        XCTAssertEqual(snapshot.version, 2, "#119 mixed-mode shape is snapshot version 2")
    }

    func testPopulatedSnapshotPreservesQuestion() {
        let snapshot = buildArmed(question: "what does this say?", [makeAppshot(windowText: "hello world")])
        XCTAssertEqual(snapshot.question, "what does this say?")
    }

    func testPopulatedSnapshotHasOneSource() {
        let snapshot = buildArmed([makeAppshot(windowText: "import Foundation\nlet x = 1")])
        XCTAssertEqual(snapshot.sources.count, 1)
    }

    func testPopulatedSnapshotSourceHasCorrectFields() {
        let text = "func greet() { print(\"Hello\") }"
        let appshot = makeAppshot(windowText: text, appName: "Xcode", windowTitle: "main.swift")
        let snapshot = buildArmed(question: "what does greet do?", [appshot])
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
        let snapshot = buildArmed(
            question: "what is this error?",
            [makeAppshot(windowText: "error: use of undeclared identifier 'foo'")]
        )
        let jsonStr = try snapshot.jsonString()
        let data = Data(jsonStr.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(obj?["kind"] as? String, "screen_text_snapshot")
        XCTAssertEqual(obj?["version"] as? Int, 2)
        XCTAssertEqual(obj?["question"] as? String, "what is this error?")
        XCTAssertFalse(obj?["fullVisionAvailable"] as? Bool ?? true)
        XCTAssertNotNil(obj?["sources"])
        XCTAssertNotNil(obj?["instruction"])
    }

    func testSnapshotJSONIsStableForIdenticalInputs() throws {
        let appshot = makeAppshot(windowText: "stable text here", capturedAt: refNow.addingTimeInterval(-60))
        let s1 = buildArmed(question: "what?", [appshot])
        let s2 = buildArmed(question: "what?", [appshot])
        XCTAssertEqual(try s1.jsonString(), try s2.jsonString(),
            "Identical inputs must produce byte-identical JSON")
    }

    // MARK: - Truncation: head+tail with correct counts

    func testTruncationProducesCorrectOriginalCount() {
        // With 1 source, budget = 8000. 10,000 chars > 8000 → truncation.
        let longText = String(repeating: "a", count: 10_000)
        let snapshot = buildArmed([makeAppshot(windowText: longText, appName: "Editor", windowTitle: "big.swift")])
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

        let snapshot = buildArmed([makeAppshot(windowText: longText)])
        let source = snapshot.sources[0]
        XCTAssertTrue(source.text.hasPrefix("S"), "Head must be preserved")
        XCTAssertTrue(source.text.hasSuffix("E"), "Tail must be preserved")
        XCTAssertTrue(source.text.contains("[truncated]"), "Elision marker must be present")
    }

    func testReturnedCharCountMatchesActualTextLength() {
        let longText = String(repeating: "x", count: 10_000)
        let snapshot = buildArmed([makeAppshot(windowText: longText)])
        let source = snapshot.sources[0]
        XCTAssertEqual(source.returnedCharCount, source.text.count,
            "returnedCharCount must equal the actual text length")
    }

    // MARK: - Mixed-source ordering and kinds (#119)

    func testMultiSourceOrderingPreserved() {
        let a1 = Appshot(windowText: "first appshot", appName: "Cursor", windowTitle: "file.swift")
        let a2 = Appshot(windowText: "second appshot", appName: "Chrome", windowTitle: "localhost")
        let snapshot = buildArmed(question: "what is on screen?", [a1, a2])
        XCTAssertEqual(snapshot.sources.count, 2)
        XCTAssertEqual(snapshot.sources[0].appName, "Cursor")
        XCTAssertEqual(snapshot.sources[1].appName, "Chrome")
    }

    func testMixedArmedAndCurrentOrderingAndKinds() {
        let armed = Appshot(windowText: "armed arc text", appName: "Arc", windowTitle: "docs")
        let current = Appshot(windowText: "current zed text", appName: "Zed", windowTitle: "main.rs")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what's on my screen?",
            armed: [armed],
            current: current,
            visionAvailable: false,
            now: refNow
        )
        XCTAssertEqual(snapshot.sources.count, 2)
        XCTAssertEqual(snapshot.sources[0].appName, "Arc")
        XCTAssertEqual(snapshot.sources[0].source, .armedAppshot,
            "Armed sources come first, labeled armed_appshot")
        XCTAssertEqual(snapshot.sources[1].appName, "Zed")
        XCTAssertEqual(snapshot.sources[1].source, .freshGrab,
            "The current frontmost grab comes last, labeled fresh_grab")
    }

    func testCurrentOnlySourceIsFreshGrabKind() {
        let current = makeAppshot(windowText: "fresh content", appName: "Arc")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q", armed: [], current: current, visionAvailable: false, now: refNow
        )
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources[0].source, .freshGrab)
    }

    func testMultiSourceBudgetDistributedAcrossArmedPlusCurrent() {
        // 2 armed + 1 current = 3 sources; each gets totalBudget/3 ≈ 2666 chars.
        let longText = String(repeating: "x", count: 10_000)
        let armed = (0..<2).map { i in
            Appshot(windowText: longText, appName: "App\(i)", windowTitle: "title\(i)")
        }
        let current = Appshot(windowText: longText, appName: "Now", windowTitle: "now")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q", armed: armed, current: current, visionAvailable: false, now: refNow
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
        let snapshot = buildArmed(appshots)
        XCTAssertEqual(snapshot.sources.count, 100,
            "No source must be silently dropped — all 100 must appear")
    }

    // MARK: - capturedSecondsAgo (#119)

    func testCapturedSecondsAgoComputedFromInjectedNow() {
        let appshot = makeAppshot(windowText: "text", capturedAt: refNow.addingTimeInterval(-240))
        let snapshot = buildArmed([appshot])
        XCTAssertEqual(snapshot.sources[0].capturedSecondsAgo, 240,
            "Age must be now - capturedAt in whole seconds")
    }

    func testCapturedSecondsAgoNilWithoutCapturedAt() {
        let snapshot = buildArmed([makeAppshot(windowText: "text", capturedAt: nil)])
        XCTAssertNil(snapshot.sources[0].capturedSecondsAgo,
            "Pre-#119 Appshots without capturedAt must yield nil age, not 0")
    }

    func testCapturedSecondsAgoClampedToZeroForFutureCapture() {
        // Clock skew should never produce a negative age.
        let appshot = makeAppshot(windowText: "text", capturedAt: refNow.addingTimeInterval(30))
        let snapshot = buildArmed([appshot])
        XCTAssertEqual(snapshot.sources[0].capturedSecondsAgo, 0)
    }

    func testCapturedSecondsAgoEncodedInJSON() throws {
        let appshot = makeAppshot(windowText: "text", capturedAt: refNow.addingTimeInterval(-90))
        let json = try buildArmed([appshot]).jsonString()
        XCTAssertTrue(json.contains("\"capturedSecondsAgo\":90"),
            "Age must appear in the serialized snapshot")
    }

    // MARK: - Empty text snapshot

    func testEmptyTextProducesValidSnapshot() {
        let current = makeAppshot(windowText: "")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "what's here?", armed: [], current: current, visionAvailable: false, now: refNow
        )
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources[0].textQuality, .empty)
        XCTAssertEqual(snapshot.sources[0].originalCharCount, 0)
        XCTAssertEqual(snapshot.sources[0].returnedCharCount, 0)
        XCTAssertFalse(snapshot.sources[0].truncated)
    }

    func testNilWindowTextProducesEmptyQualitySource() {
        let snapshot = buildArmed([makeAppshot(windowText: nil)])
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.sources[0].textQuality, .empty)
    }

    func testNoSourcesProducesEmptySourcesArray() {
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q", armed: [], current: nil, visionAvailable: false, now: refNow
        )
        XCTAssertEqual(snapshot.sources.count, 0)
    }

    // MARK: - visionAvailable branches

    func testVisionAvailableFalseHasNoEscalationInstruction() {
        let snapshot = buildArmed([makeAppshot(windowText: "some text")])
        XCTAssertFalse(snapshot.fullVisionAvailable)
        XCTAssertFalse(snapshot.instruction.contains("analyze_screen"),
            "M4a: no escalation to analyze_screen in instruction when visionAvailable=false")
    }

    func testVisionAvailableTrueHasEscalationInstruction() {
        let snapshot = buildArmed([makeAppshot(windowText: "some text")], visionAvailable: true)
        XCTAssertTrue(snapshot.fullVisionAvailable)
        XCTAssertTrue(snapshot.instruction.contains("analyze_screen"),
            "M4b path: instruction must reference analyze_screen when visionAvailable=true")
    }

    // MARK: - Instruction: name-your-source (#119)

    func testInstructionRequiresNamingSourceWindow() {
        let snapshot = buildArmed([makeAppshot(windowText: "text")])
        XCTAssertTrue(snapshot.instruction.contains("name the window"),
            "Instruction must require the model to name its source window")
        XCTAssertTrue(snapshot.instruction.contains("CURRENT frontmost"),
            "Instruction must explain fresh_grab is the current frontmost window")
    }

    // MARK: - Source kind encoding

    func testFreshGrabSourceKindEncoded() throws {
        let current = makeAppshot(windowText: "fresh content")
        let snapshot = ScreenTextSnapshotBuilder.build(
            question: "q", armed: [], current: current, visionAvailable: false, now: refNow
        )
        let json = try snapshot.jsonString()
        XCTAssertTrue(json.contains("fresh_grab"),
            "fresh_grab source kind must appear in JSON")
    }

    func testArmedAppshotSourceKindEncoded() throws {
        let json = try buildArmed([makeAppshot(windowText: "armed content")]).jsonString()
        XCTAssertTrue(json.contains("armed_appshot"),
            "armed_appshot source kind must appear in JSON")
    }

    // MARK: - Text quality

    func testShortTextProducesSparseQuality() {
        let snapshot = buildArmed([makeAppshot(windowText: "hi")])
        XCTAssertEqual(snapshot.sources[0].textQuality, .sparse)
    }

    func testSubstantialTextProducesOkQuality() {
        let snapshot = buildArmed([makeAppshot(windowText: String(repeating: "a", count: 100))])
        XCTAssertEqual(snapshot.sources[0].textQuality, .ok)
    }

    // MARK: - Pure: no AppKit/AX imports (compile-time guarantee — no import needed here)
}
