import XCTest
@testable import TNTPlatformMac
import AppKit  // for CGEventFlags in chord tests

/// Tests for `AppShotHotkeyGestureRecognizer` and the Appshot `HotkeyChord`
/// defaults (issue #101).
///
/// Acceptance criteria:
/// - ⌃⌥⇧Space default chord defined + configurable; display string correct.
/// - Press-only recognition: keyDown fires exactly one event; repeats fire nothing; keyUp fires nothing.
/// - The voice chord's hold/tap behavior is untouched (existing recognizer tests green).
/// - Both chords coexist: ⌃⌥⇧Space does not also fire the ⌃⌥Space voice chord.
/// - Pure logic unit-tested without CGEventTap.
final class AppShotHotkeyGestureRecognizerTests: XCTestCase {

    // MARK: - Press-only recognition

    func testFirstKeyDownFiresCaptureAppshot() {
        var r = AppShotHotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(), .captureAppshot,
            "First keyDown must fire .captureAppshot")
    }

    func testKeyDownWhileHeldIsNoChange() {
        var r = AppShotHotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(), .captureAppshot)
        // Auto-repeat: key held, second keyDown fires while isPressed = true.
        XCTAssertEqual(r.keyDown(), .noChange,
            "Auto-repeat keyDown must produce .noChange")
        XCTAssertEqual(r.keyDown(), .noChange,
            "Further repeats must also produce .noChange")
    }

    func testKeyUpIsNoChange() {
        var r = AppShotHotkeyGestureRecognizer()
        _ = r.keyDown()
        XCTAssertEqual(r.keyUp(), .noChange,
            "keyUp must always be .noChange — capture happens on keyDown")
    }

    func testKeyUpWithoutPrecedingKeyDownIsNoChange() {
        var r = AppShotHotkeyGestureRecognizer()
        XCTAssertEqual(r.keyUp(), .noChange,
            "Orphan keyUp must be .noChange")
    }

    func testSecondPressAfterReleaseFiresAgain() {
        var r = AppShotHotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(), .captureAppshot)
        r.keyUp()  // release
        XCTAssertEqual(r.keyDown(), .captureAppshot,
            "A new press after release must fire .captureAppshot again")
    }

    func testIsPressFlagSetAfterKeyDown() {
        var r = AppShotHotkeyGestureRecognizer()
        XCTAssertFalse(r.isPressed, "Initial state must be not pressed")
        _ = r.keyDown()
        XCTAssertTrue(r.isPressed, "isPressed must be true after keyDown")
    }

    func testIsPressFlagClearedAfterKeyUp() {
        var r = AppShotHotkeyGestureRecognizer()
        _ = r.keyDown()
        r.keyUp()
        XCTAssertFalse(r.isPressed, "isPressed must be false after keyUp")
    }

    func testExactlyOneCapturePerPress() {
        var r = AppShotHotkeyGestureRecognizer()
        var captureCount = 0

        // Simulate: down → repeat × 5 → up
        if r.keyDown() == .captureAppshot { captureCount += 1 }
        for _ in 0..<5 {
            if r.keyDown() == .captureAppshot { captureCount += 1 }
        }
        r.keyUp()

        XCTAssertEqual(captureCount, 1,
            "Exactly one .captureAppshot must fire per logical press, regardless of auto-repeat")
    }

    // MARK: - Default Appshot chord

    func testAppshotDefaultChordIsControlOptionShiftSpace() {
        let chord = HotkeyChord.appshotDefault
        XCTAssertEqual(chord.modifiers, [.control, .option, .shift])
        XCTAssertEqual(chord.key, .space)
    }

    func testAppshotDefaultDisplayString() {
        // Modifier.allCases order: command, option, shift, control
        // So ⌃⌥⇧Space = option+shift+control+space
        let chord = HotkeyChord.appshotDefault
        // The displayString uses allCases ordering: command, option, shift, control
        XCTAssertTrue(chord.displayString.contains("option"),
            "Display string must include 'option'")
        XCTAssertTrue(chord.displayString.contains("shift"),
            "Display string must include 'shift'")
        XCTAssertTrue(chord.displayString.contains("control"),
            "Display string must include 'control'")
        XCTAssertTrue(chord.displayString.hasSuffix("space"),
            "Display string must end with 'space'")
    }

    func testAppshotDefaultUserDefaultsKey() {
        XCTAssertEqual(HotkeyChord.appshotUserDefaultsKey, "appshotHotkey")
    }

    func testLoadAppshotChordFromUserDefaults() {
        let suite = UserDefaults(suiteName: "TNTAppshotChordTest-\(UUID().uuidString)")!
        suite.set("control+option+shift+space", forKey: HotkeyChord.appshotUserDefaultsKey)
        let chord = HotkeyChord.loadAppshot(from: suite)
        XCTAssertEqual(chord, HotkeyChord(modifiers: [.control, .option, .shift], key: .space))
    }

    func testLoadAppshotChordFallsBackToDefaultWhenMissing() {
        let suite = UserDefaults(suiteName: "TNTAppshotChordTest-\(UUID().uuidString)")!
        XCTAssertEqual(HotkeyChord.loadAppshot(from: suite), .appshotDefault)
    }

    func testLoadAppshotChordFallsBackToDefaultOnGarbageValue() {
        let suite = UserDefaults(suiteName: "TNTAppshotChordTest-\(UUID().uuidString)")!
        suite.set("not a chord", forKey: HotkeyChord.appshotUserDefaultsKey)
        XCTAssertEqual(HotkeyChord.loadAppshot(from: suite), .appshotDefault)
    }

    // MARK: - Superset-chord non-interference

    func testVoiceChordDoesNotMatchAppshotChordFlags() {
        // The voice chord is ⌃⌥Space — pressing it must NOT match the Appshot chord (⌃⌥⇧Space).
        // The Appshot chord requires Shift in addition; the voice press lacks it.
        let appshotChord = HotkeyChord.appshotDefault
        let spaceKeyCode = HotkeyChord.Key.space.cgKeyCode
        let voiceFlags: CGEventFlags = [.maskControl, .maskAlternate]  // ⌃⌥ only, no shift

        XCTAssertFalse(
            appshotChord.matchesKeyDown(flags: voiceFlags, keyCode: spaceKeyCode),
            "⌃⌥Space (voice chord) must NOT match the ⌃⌥⇧Space Appshot chord — superset guard"
        )
    }

    func testAppshotChordDoesNotMatchVoiceChordFlags() {
        // The voice chord is ⌃⌥Space — it must not fire when ⌃⌥⇧Space is pressed.
        let voiceChord = HotkeyChord.default  // ⌃⌥Space
        let spaceKeyCode = HotkeyChord.Key.space.cgKeyCode
        let appshotFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]  // ⌃⌥⇧

        XCTAssertFalse(
            voiceChord.matchesKeyDown(flags: appshotFlags, keyCode: spaceKeyCode),
            "⌃⌥⇧Space (Appshot chord) must NOT match the ⌃⌥Space voice chord — superset guard"
        )
    }

    func testAppshotChordMatchesWithExactModifiers() {
        let chord = HotkeyChord.appshotDefault
        let spaceKeyCode = HotkeyChord.Key.space.cgKeyCode
        let appshotFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift]

        XCTAssertTrue(
            chord.matchesKeyDown(flags: appshotFlags, keyCode: spaceKeyCode),
            "⌃⌥⇧Space must match the Appshot chord when all three modifiers are held"
        )
    }

    // MARK: - Voice chord hold/tap still works (regression)

    func testVoiceRecognizerHoldTapUnaffected() {
        // Existing HotkeyGestureRecognizer must still distinguish hold vs tap.
        var r = HotkeyGestureRecognizer()
        XCTAssertEqual(r.keyDown(at: 0.0), .startListening)
        XCTAssertEqual(r.keyUp(at: 0.240), .noChange)  // tap — stays latched
        XCTAssertTrue(r.isListening, "Voice recognizer tap latch must still work")
    }
}
