import XCTest
@testable import TNTCore

/// Tests for `ExecutorAction`, `ActionResult`, and `blastRadius` (issue #37).
///
/// Acceptance criteria:
/// - ExecutorAction is a closed enum with exactly the v0 cases + target binding.
/// - No run(String) or arbitrary execution path.
/// - ActionResult enumerates done/needsConfirmation/targetChanged/permissionMissing/unsupported + Codable.
/// - blastRadius: confirmRequired for pasteText/pressReturn; reversible for activate/focus.
final class ExecutorActionTests: XCTestCase {

    // MARK: - BlastRadius table-driven test

    func testBlastRadiusIsReversibleForActivateApp() {
        let action = ExecutorAction.activateApp(.agent(.claudeCode))
        XCTAssertEqual(action.blastRadius, .reversible)
    }

    func testBlastRadiusIsReversibleForFocusWindow() {
        let action = ExecutorAction.focusWindow(target: .agent(.cursor))
        XCTAssertEqual(action.blastRadius, .reversible)
    }

    func testBlastRadiusIsConfirmRequiredForPasteText() {
        let action = ExecutorAction.pasteText(
            "Add a unit test to rate-limit middleware.",
            target: .agent(.claudeCode)
        )
        XCTAssertEqual(action.blastRadius, .confirmRequired)
    }

    func testBlastRadiusIsConfirmRequiredForPressReturn() {
        let action = ExecutorAction.pressReturn(target: .bundleID("com.cursor.editor"))
        XCTAssertEqual(action.blastRadius, .confirmRequired)
    }

    // MARK: - ActionTarget

    func testActionTargetAgentEquality() {
        XCTAssertEqual(ActionTarget.agent(.claudeCode), ActionTarget.agent(.claudeCode))
        XCTAssertNotEqual(ActionTarget.agent(.claudeCode), ActionTarget.agent(.cursor))
    }

    func testActionTargetBundleID() {
        let target = ActionTarget.bundleID("com.cursor.editor")
        if case .bundleID(let id) = target {
            XCTAssertEqual(id, "com.cursor.editor")
        } else {
            XCTFail("Expected bundleID case")
        }
    }

    func testActionTargetTNTApp() {
        let target = ActionTarget.tntApp
        XCTAssertEqual(target, .tntApp)
    }

    // MARK: - ExecutorAction cases present

    func testExecutorActionCasesArePresent() {
        // Compile-time proof that all v0 cases exist (if any were missing,
        // the exhaustive switch below would fail to compile).
        let actions: [ExecutorAction] = [
            .activateApp(.agent(.claudeCode)),
            .focusWindow(target: .tntApp),
            .pasteText("Hello, Claude Code.", target: .agent(.claudeCode)),
            .pressReturn(target: .bundleID("com.cursor.editor")),
        ]
        for action in actions {
            switch action {
            case .activateApp: break
            case .focusWindow: break
            case .pasteText:   break
            case .pressReturn: break
            }
        }
        XCTAssertEqual(actions.count, 4)
    }

    func testExecutorActionCarriesTargetBinding() {
        let action = ExecutorAction.pasteText(
            "Rate limit per IP.",
            target: .agent(.claudeCode)
        )
        guard case .pasteText(let text, let target) = action else {
            XCTFail("Expected pasteText")
            return
        }
        XCTAssertEqual(text, "Rate limit per IP.")
        XCTAssertEqual(target, .agent(.claudeCode))
    }

    // MARK: - ActionResult Codable round-trips

    func testActionResultDoneRoundTrip() throws {
        try assertRoundTrips(.done, expectedType: "done")
    }

    func testActionResultNeedsConfirmationRoundTrip() throws {
        try assertRoundTrips(.needsConfirmation, expectedType: "needs_confirmation")
    }

    func testActionResultTargetChangedRoundTrip() throws {
        try assertRoundTrips(.targetChanged, expectedType: "target_changed")
    }

    func testActionResultPermissionMissingRoundTrip() throws {
        try assertRoundTrips(.permissionMissing, expectedType: "permission_missing")
    }

    func testActionResultUnsupportedRoundTrip() throws {
        try assertRoundTrips(.unsupported, expectedType: "unsupported")
    }

    func testActionResultDecodesAllCases() throws {
        let cases: [(String, ActionResult)] = [
            ("done",               .done),
            ("needs_confirmation", .needsConfirmation),
            ("target_changed",     .targetChanged),
            ("permission_missing", .permissionMissing),
            ("unsupported",        .unsupported),
        ]
        for (typeString, expected) in cases {
            let json = "{\"type\":\"\(typeString)\"}"
            let decoded = try JSONDecoder().decode(ActionResult.self, from: Data(json.utf8))
            XCTAssertEqual(decoded, expected, "Failed to decode type=\(typeString)")
        }
    }

    func testActionResultEncodesSNakeCaseTypeStrings() throws {
        let result = ActionResult.needsConfirmation
        let data = try JSONEncoder().encode(result)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "needs_confirmation",
            "ActionResult must encode with snake_case type strings for the model's function_call_output")
    }

    // MARK: - Helpers

    private func assertRoundTrips(_ result: ActionResult, expectedType: String) throws {
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ActionResult.self, from: data)
        XCTAssertEqual(decoded, result)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, expectedType)
    }
}
