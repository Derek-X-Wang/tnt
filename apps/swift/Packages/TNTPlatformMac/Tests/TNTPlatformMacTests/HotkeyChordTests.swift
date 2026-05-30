import XCTest
@testable import TNTPlatformMac

/// Default chord, parsing, round-tripping, and event-matching for
/// `HotkeyChord`.
///
/// The string form (`"option+space"`, `"control+space"`) is the contract
/// for `defaults write com.derekxwang.tnt.companion hotkey …` — any drift
/// here breaks the acceptance criterion that overrides survive a relaunch.
final class HotkeyChordTests: XCTestCase {

    func testDefaultChordIsControlOptionSpace() {
        // ⌃⌥Space — deliberately three-key to dodge Spotlight (⌘Space),
        // Raycast (⌥Space), and input-source switch (⌃Space).
        let d = HotkeyChord.default
        XCTAssertEqual(d.modifiers, [.control, .option])
        XCTAssertEqual(d.key, .space)
        // displayString emits modifiers in Modifier.allCases order
        // (command, option, shift, control) then the key.
        XCTAssertEqual(d.displayString, "option+control+space")
    }

    func testParseOptionSpace() {
        let chord = HotkeyChord.parse("option+space")
        XCTAssertEqual(chord, HotkeyChord(modifiers: [.option], key: .space))
    }

    func testParseControlSpaceMatchesAcceptanceExample() {
        // The issue body lists `defaults write com.derekxwang.tnt.companion
        // hotkey "control+space"` as the override scenario. Round-trip that
        // exact form.
        let chord = HotkeyChord.parse("control+space")
        XCTAssertEqual(chord, HotkeyChord(modifiers: [.control], key: .space))
        XCTAssertEqual(chord?.displayString, "control+space")
    }

    func testParseAcceptsMultipleModifiersInAnyOrder() {
        let a = HotkeyChord.parse("option+command+space")
        let b = HotkeyChord.parse("command+option+space")
        let expected = HotkeyChord(modifiers: [.option, .command], key: .space)
        XCTAssertEqual(a, expected)
        XCTAssertEqual(b, expected)
        // displayString uses canonical modifier order so the override is
        // reproducible regardless of how the user typed it.
        XCTAssertEqual(a?.displayString, b?.displayString)
    }

    func testParseIsCaseInsensitiveAndTrimsWhitespace() {
        XCTAssertEqual(
            HotkeyChord.parse("  Option+SPACE "),
            HotkeyChord(modifiers: [.option], key: .space)
        )
    }

    func testParseRejectsUnknownKey() {
        XCTAssertNil(HotkeyChord.parse("option+banana"))
    }

    func testParseRejectsUnknownModifier() {
        XCTAssertNil(HotkeyChord.parse("hyper+space"))
    }

    func testParseRejectsEmpty() {
        XCTAssertNil(HotkeyChord.parse(""))
        XCTAssertNil(HotkeyChord.parse("   "))
    }

    func testLoadFromUserDefaultsHonoursOverride() {
        let suite = UserDefaults(suiteName: "TNTHotkeyTestSuite-\(UUID().uuidString)")!
        suite.set("control+space", forKey: "hotkey")
        XCTAssertEqual(
            HotkeyChord.load(from: suite, key: "hotkey"),
            HotkeyChord(modifiers: [.control], key: .space)
        )
    }

    func testLoadFromUserDefaultsFallsBackToDefaultWhenMissing() {
        let suite = UserDefaults(suiteName: "TNTHotkeyTestSuite-\(UUID().uuidString)")!
        XCTAssertEqual(HotkeyChord.load(from: suite, key: "hotkey"), .default)
    }

    func testLoadFromUserDefaultsFallsBackToDefaultOnGarbageValue() {
        let suite = UserDefaults(suiteName: "TNTHotkeyTestSuite-\(UUID().uuidString)")!
        suite.set("not a chord", forKey: "hotkey")
        XCTAssertEqual(HotkeyChord.load(from: suite, key: "hotkey"), .default)
    }

    // MARK: - Event matching

    private var space: UInt16 { HotkeyChord.Key.space.cgKeyCode }

    func testMatchesKeyDownRequiresFullChord() {
        let chord = HotkeyChord(modifiers: [.control, .option], key: .space)
        XCTAssertTrue(chord.matchesKeyDown(flags: [.maskControl, .maskAlternate], keyCode: space))
    }

    func testMatchesKeyDownRejectsMissingModifier() {
        let chord = HotkeyChord(modifiers: [.control, .option], key: .space)
        // Only one of the two required modifiers held.
        XCTAssertFalse(chord.matchesKeyDown(flags: [.maskAlternate], keyCode: space))
    }

    func testMatchesKeyDownRejectsExtraModifier() {
        let chord = HotkeyChord(modifiers: [.control, .option], key: .space)
        XCTAssertFalse(chord.matchesKeyDown(flags: [.maskControl, .maskAlternate, .maskShift], keyCode: space))
    }

    func testMatchesKeyDownRejectsWrongKey() {
        let chord = HotkeyChord(modifiers: [.option], key: .space)
        XCTAssertFalse(chord.matchesKeyDown(flags: [.maskAlternate], keyCode: space &+ 1))
    }

    func testMatchesKeyDownIgnoresUntrackedFlagBits() {
        // Caps-lock toggled on must not block the chord.
        let chord = HotkeyChord(modifiers: [.option], key: .space)
        XCTAssertTrue(chord.matchesKeyDown(flags: [.maskAlternate, .maskAlphaShift], keyCode: space))
    }

    func testMatchesKeyUpClosesOnKeyAloneEvenWithModifierReleased() {
        // The M0 regression: the user releases ⌃⌥ a few ms before Space, so
        // Space's keyUp arrives with NO modifier flags. It must still close
        // the gesture, otherwise the lamp desyncs into a stuck/toggle state.
        let chord = HotkeyChord(modifiers: [.control, .option], key: .space)
        XCTAssertTrue(chord.matchesKeyUp(keyCode: space))
    }

    func testMatchesKeyUpRejectsWrongKey() {
        let chord = HotkeyChord(modifiers: [.control, .option], key: .space)
        XCTAssertFalse(chord.matchesKeyUp(keyCode: space &+ 1))
    }
}
