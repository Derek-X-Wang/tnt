import XCTest
@testable import TNTRealtime

/// Tests for the M4a Tier-1 screen text tool and armed-context note (issue #99).
///
/// Acceptance criteria:
/// - Tool name is `read_screen_text`.
/// - `question` is required (`required: ["question"]`, `additionalProperties: false`).
/// - No other args besides `question`.
/// - `look_at_screen` is gone — no dead schema left.
/// - Composition helper `withScreenTools()` appends the tool alongside the
///   Rewrite tools; golden composition test green.
/// - `armedAppshotsContextNote` untouched (now references `read_screen_text`).
/// - `swift test` green for TNTRealtime.
final class ScreenTextToolTests: XCTestCase {

    // MARK: - Tool definition

    func testScreenTextToolNameIsReadScreenText() {
        XCTAssertEqual(ScreenTextTool.tool.name, "read_screen_text")
    }

    func testScreenTextToolTypeIsFunction() {
        XCTAssertEqual(ScreenTextTool.tool.type, "function")
    }

    func testScreenTextToolRequiresQuestion() throws {
        let data = try JSONEncoder().encode(ScreenTextTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        XCTAssertEqual(required, ["question"],
            "read_screen_text must have exactly one required parameter: question")
    }

    func testScreenTextToolParameterSchemaIsObject() throws {
        let data = try JSONEncoder().encode(ScreenTextTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertEqual(params?["additionalProperties"] as? Bool, false)
    }

    func testScreenTextToolHasQuestionProperty() throws {
        let data = try JSONEncoder().encode(ScreenTextTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["question"],
            "read_screen_text must expose a 'question' parameter")
    }

    func testScreenTextToolHasOnlyQuestionProperty() throws {
        // No other args — question is the sole parameter.
        let data = try JSONEncoder().encode(ScreenTextTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        XCTAssertEqual(properties?.count, 1,
            "read_screen_text must have exactly one property: question")
    }

    // MARK: - Session config includes exactly one screen tool

    func testSessionConfigIncludesExactlyOneScreenTool() throws {
        let body = SessionUpdate.bilingualV0().session.withScreenTools()
        XCTAssertEqual(body.tools?.count, 1)
        XCTAssertEqual(body.tools?.first?.name, "read_screen_text")
        XCTAssertEqual(body.toolChoice, "auto")

        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessionJSON = json?["session"] as? [String: Any]

        // GA key: "tools"
        let tools = sessionJSON?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "read_screen_text")

        // GA key: "tool_choice"
        XCTAssertEqual(sessionJSON?["tool_choice"] as? String, "auto")
    }

    func testScreenToolComposesWithRewriteTools() throws {
        // Composition: Rewrite tools + Tier-1 screen tool.
        let body = SessionUpdate.bilingualV0().session
            .withRewriteTools()    // compose_agent_prompt, deliver_prompt
            .withScreenTools()     // read_screen_text
        XCTAssertEqual(body.tools?.count, 3,
            "Composition of Rewrite + screen tools must produce 3 total")
        XCTAssertEqual(body.tools?[0].name, "compose_agent_prompt")
        XCTAssertEqual(body.tools?[1].name, "deliver_prompt")
        XCTAssertEqual(body.tools?[2].name, "read_screen_text")
    }

    func testScreenToolRoundTripsCleanly() throws {
        // Composition must round-trip without error.
        let body = SessionUpdate.bilingualV0().session
            .withRewriteTools()
            .withScreenTools()
        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(SessionUpdate.self, from: data)
        XCTAssertEqual(decoded.type, "session.update")
    }

    // MARK: - armedAppshotsContextNote — pure function, golden tests (references read_screen_text)

    func testZeroAppshotsProducesEmptyString() {
        let note = armedAppshotsContextNote(count: 0)
        XCTAssertEqual(note, "",
            "N=0: no note needed when no Appshots are armed")
    }

    func testOneAppshotProducesSingularNote() {
        let note = armedAppshotsContextNote(count: 1)
        XCTAssertTrue(note.contains("1 appshot"),
            "N=1: note must say '1 appshot' (singular)")
        XCTAssertTrue(note.contains("read_screen_text"),
            "N=1: note must reference the Tier-1 tool name read_screen_text")
    }

    func testTwoAppshotProducesPluralNote() {
        let note = armedAppshotsContextNote(count: 2)
        XCTAssertTrue(note.contains("2 appshots"),
            "N=2: note must say '2 appshots' (plural)")
        XCTAssertTrue(note.contains("read_screen_text"))
    }

    func testArmedNoteIsNonEmptyForPositiveCounts() {
        for n in 1...5 {
            XCTAssertFalse(armedAppshotsContextNote(count: n).isEmpty,
                "armedAppshotsContextNote must be non-empty for count=\(n)")
        }
    }

    // MARK: - Golden-encode composition test

    func testScreenToolsGoldenComposition() throws {
        // Stable key order: compose_agent_prompt, deliver_prompt, read_screen_text.
        let update = SessionUpdate(
            session: SessionUpdate.bilingualV0().session
                .withRewriteTools()
                .withScreenTools()
        )
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessionJSON = json?["session"] as? [String: Any]
        let tools = sessionJSON?["tools"] as? [[String: Any]]
        let names = tools?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["compose_agent_prompt", "deliver_prompt", "read_screen_text"])
    }

    // MARK: - Regression: unknown frames still decode to .unknown

    func testUnknownFramesStillDecodeToUnknown() throws {
        let raw = #"{"type":"response.function_call_arguments.delta","call_id":"c"}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .unknown = event else {
            XCTFail("Expected .unknown for unmodelled frame")
            return
        }
    }
}
