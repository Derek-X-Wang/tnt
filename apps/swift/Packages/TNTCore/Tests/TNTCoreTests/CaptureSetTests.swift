import XCTest
@testable import TNTCore

/// Tests for `CaptureSet`, `AgentRef`, and `ProjectRef` — the shared
/// data types introduced for M1 (Rewrite to Worker Agent prompt).
///
/// Acceptance criteria (issue #29):
/// - `AgentRef`, `ProjectRef`, `CaptureSet` are Codable/Sendable with
///   the specified fields.
/// - `CaptureSet.empty.isEmpty == true`; a populated set is not empty.
/// - `AgentRef.claudeCode.key == "claude-code"`.
/// - Codable round-trip tests for all three types.
/// - `AppConfig` gains `cognitiveModel` with default + override.
final class CaptureSetTests: XCTestCase {

    // MARK: - AgentRef

    func testAgentRefCanonicalClaudeCodeKey() {
        XCTAssertEqual(AgentRef.claudeCode.key, "claude-code")
        XCTAssertEqual(AgentRef.claudeCode.displayName, "Claude Code")
    }

    func testAgentRefCanonicalCursorKey() {
        XCTAssertEqual(AgentRef.cursor.key, "cursor")
        XCTAssertEqual(AgentRef.cursor.displayName, "Cursor")
    }

    func testAgentRefCodableRoundTripFull() throws {
        let original = AgentRef(key: "opencode", displayName: "OpenCode")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentRef.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAgentRefCodableRoundTripNilDisplayName() throws {
        let original = AgentRef(key: "custom-agent")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentRef.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.displayName)
    }

    func testAgentRefHashable() {
        var set = Set<AgentRef>()
        set.insert(.claudeCode)
        set.insert(.claudeCode)
        XCTAssertEqual(set.count, 1, "Same AgentRef must hash to same bucket")
        set.insert(.cursor)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - ProjectRef

    func testProjectRefCodableRoundTripFull() throws {
        let original = ProjectRef(name: "tnt", path: "/Users/dev/tnt")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectRef.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testProjectRefCodableRoundTripNilPath() throws {
        let original = ProjectRef(name: "browser-project")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectRef.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.path)
    }

    // MARK: - CaptureSet

    func testCaptureSetEmptyIsEmpty() {
        XCTAssertTrue(CaptureSet.empty.isEmpty)
        XCTAssertNil(CaptureSet.empty.appName)
        XCTAssertNil(CaptureSet.empty.windowTitle)
        XCTAssertNil(CaptureSet.empty.selectedText)
        XCTAssertNil(CaptureSet.empty.project)
    }

    func testCaptureSetPopulatedIsNotEmpty() {
        let set = CaptureSet(appName: "Cursor")
        XCTAssertFalse(set.isEmpty)
    }

    func testCaptureSetPopulatedOnlySelectedTextIsNotEmpty() {
        let set = CaptureSet(selectedText: "fn rate_limit()")
        XCTAssertFalse(set.isEmpty)
    }

    func testCaptureSetCodableRoundTripFull() throws {
        let original = CaptureSet(
            appName: "Cursor",
            windowTitle: "tnt — VoiceTurnController.swift",
            selectedText: "private func sendCommitAndCreate()",
            project: ProjectRef(name: "tnt", path: "/Users/dev/tnt")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCaptureSetCodableRoundTripAllNils() throws {
        let original = CaptureSet.empty
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isEmpty)
    }

    func testCaptureSetCodableRoundTripNilProject() throws {
        let original = CaptureSet(appName: "Safari", windowTitle: "GitHub")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.project)
    }

    func testCaptureSetSnakeCaseKeys() throws {
        // Verify the JSON wire keys use snake_case as required by the
        // data-shape spec.
        let set = CaptureSet(
            appName: "Xcode",
            windowTitle: "main.swift",
            selectedText: "let x = 1"
        )
        let data = try JSONEncoder().encode(set)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["app_name"])
        XCTAssertNotNil(json?["window_title"])
        XCTAssertNotNil(json?["selected_text"])
        // project is nil — must not appear as a key at all OR appear as null
        // (either is acceptable for Codable; just verify app_name exists)
        XCTAssertEqual(json?["app_name"] as? String, "Xcode")
    }
}
