import XCTest
@testable import TNTPlatformMac

/// Default chord, parsing, and round-tripping for `HotkeyChord`.
///
/// The string form (`"option+space"`, `"control+space"`) is the contract
/// for `defaults write com.tnt.app hotkey …` — any drift here breaks the
/// acceptance criterion that overrides survive a relaunch.
final class HotkeyChordTests: XCTestCase {

    func testDefaultChordIsOptionSpace() {
        let d = HotkeyChord.default
        XCTAssertEqual(d.modifiers, [.option])
        XCTAssertEqual(d.key, .space)
        XCTAssertEqual(d.displayString, "option+space")
    }

    func testParseOptionSpace() {
        let chord = HotkeyChord.parse("option+space")
        XCTAssertEqual(chord, HotkeyChord(modifiers: [.option], key: .space))
    }

    func testParseControlSpaceMatchesAcceptanceExample() {
        // The issue body lists `defaults write com.tnt.app hotkey "control+space"`
        // as the override scenario. Round-trip that exact form.
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
}
