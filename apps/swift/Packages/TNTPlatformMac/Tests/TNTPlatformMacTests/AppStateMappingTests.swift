import AppKit
import XCTest
@testable import TNTPlatformMac

/// Smoke tests for the State Lamp mappings exposed by `AppState`.
///
/// Per the M0/S2 acceptance criteria, the State Lamp must map every
/// `AppState` to a deterministic SF Symbol, tint, and menu title so future
/// slices can flip the lamp without re-validating the visual contract.
final class AppStateMappingTests: XCTestCase {

    private let allStates: [AppState] = [.idle, .listening, .thinking, .speaking]

    func testSymbolNameMappingIsExhaustiveAndDistinct() {
        XCTAssertEqual(AppState.idle.symbolName, "circle")
        XCTAssertEqual(AppState.listening.symbolName, "waveform")
        XCTAssertEqual(AppState.thinking.symbolName, "brain")
        XCTAssertEqual(AppState.speaking.symbolName, "speaker.wave.2.fill")

        let symbols = Set(allStates.map(\.symbolName))
        XCTAssertEqual(symbols.count, allStates.count, "Each AppState must have a distinct SF Symbol so the lamp is visually unambiguous.")
        XCTAssertFalse(symbols.contains(""), "No AppState may map to an empty SF Symbol name.")
    }

    func testTintMappingIsExhaustiveAndDistinct() {
        XCTAssertEqual(AppState.idle.tint, .secondary)
        XCTAssertEqual(AppState.listening.tint, .green)
        XCTAssertEqual(AppState.thinking.tint, .orange)
        XCTAssertEqual(AppState.speaking.tint, .blue)

        let tints = Set(allStates.map(\.tint))
        XCTAssertEqual(tints.count, allStates.count, "Each AppState must have a distinct tint so the lamp is visually unambiguous.")
    }

    func testMenuTitleMappingMatchesAcceptanceText() {
        // The acceptance demo specifies "TNT — idle" verbatim; other states
        // follow the same `TNT — <state>` shape so the menu title is the
        // single source of truth for the lamp label.
        XCTAssertEqual(AppState.idle.menuTitle, "TNT — idle")
        XCTAssertEqual(AppState.listening.menuTitle, "TNT — listening")
        XCTAssertEqual(AppState.thinking.menuTitle, "TNT — thinking")
        XCTAssertEqual(AppState.speaking.menuTitle, "TNT — speaking")

        for state in allStates {
            XCTAssertTrue(state.menuTitle.hasPrefix("TNT — "), "Menu title must start with 'TNT — ' for \(state).")
            XCTAssertFalse(state.menuTitle.isEmpty)
        }
    }

    func testTintResolvesToConcreteAppKitColor() {
        // The State Lamp is rendered in AppKit; the typed tint must
        // resolve to a concrete `NSColor` for `NSStatusItem.button.contentTintColor`.
        XCTAssertEqual(AppStateTint.secondary.nsColor, .secondaryLabelColor)
        XCTAssertEqual(AppStateTint.green.nsColor, .systemGreen)
        XCTAssertEqual(AppStateTint.orange.nsColor, .systemOrange)
        XCTAssertEqual(AppStateTint.blue.nsColor, .systemBlue)
    }
}
