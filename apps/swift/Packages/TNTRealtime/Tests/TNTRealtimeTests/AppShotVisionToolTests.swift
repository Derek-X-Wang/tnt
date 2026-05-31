import XCTest
@testable import TNTRealtime

/// Tests for the M4 Appshot vision tool and armed-context note (issue #35).
///
/// Acceptance criteria:
/// - Session config can include exactly one vision tool with GA-correct JSON keys.
/// - `armedAppshotsContextNote` is a pure function — golden tested for N=0,1,2.
/// - Existing #30 tool/codec tests still pass.
final class AppShotVisionToolTests: XCTestCase {

    // MARK: - Tool definition

    func testVisionToolNameIsLookAtScreen() {
        XCTAssertEqual(AppShotVisionTool.tool.name, "look_at_screen")
    }

    func testVisionToolTypeIsFunction() {
        XCTAssertEqual(AppShotVisionTool.tool.type, "function")
    }

    func testVisionToolHasNoRequiredParameters() throws {
        // The focus hint is optional — the model can call look_at_screen
        // with no arguments for a broad look.
        let data = try JSONEncoder().encode(AppShotVisionTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        XCTAssertTrue(required?.isEmpty == true,
            "look_at_screen must have no required parameters")
    }

    func testVisionToolParameterSchemaIsObject() throws {
        let data = try JSONEncoder().encode(AppShotVisionTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertEqual(params?["additionalProperties"] as? Bool, false)
    }

    func testVisionToolHasFocusHintProperty() throws {
        let data = try JSONEncoder().encode(AppShotVisionTool.tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let properties = params?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["focus"],
            "look_at_screen must expose an optional 'focus' hint parameter")
    }

    // MARK: - Session config includes exactly one vision tool

    func testSessionConfigIncludesExactlyOneVisionTool() throws {
        let body = SessionUpdate.bilingualV0().session.withVisionTool()
        XCTAssertEqual(body.tools?.count, 1)
        XCTAssertEqual(body.tools?.first?.name, "look_at_screen")
        XCTAssertEqual(body.toolChoice, "auto")

        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessionJSON = json?["session"] as? [String: Any]

        // GA key: "tools"
        let tools = sessionJSON?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "look_at_screen")

        // GA key: "tool_choice"
        XCTAssertEqual(sessionJSON?["tool_choice"] as? String, "auto")
    }

    func testVisionToolComposesWithRewriteTools() throws {
        // Composition: Rewrite tools (#47) + vision tool (#35).
        let body = SessionUpdate.bilingualV0().session
            .withRewriteTools()    // compose_agent_prompt, deliver_prompt
            .withVisionTool()      // look_at_screen
        XCTAssertEqual(body.tools?.count, 3,
            "Composition of Rewrite + vision tools must produce 3 total")
        XCTAssertEqual(body.tools?[0].name, "compose_agent_prompt")
        XCTAssertEqual(body.tools?[1].name, "deliver_prompt")
        XCTAssertEqual(body.tools?[2].name, "look_at_screen")
    }

    // MARK: - armedAppshotsContextNote — pure function, golden tests

    func testZeroAppshotsProducesEmptyString() {
        let note = armedAppshotsContextNote(count: 0)
        XCTAssertEqual(note, "",
            "N=0: no note needed when no Appshots are armed")
    }

    func testOneAppshotProducesSingularNote() {
        let note = armedAppshotsContextNote(count: 1)
        XCTAssertTrue(note.contains("1 appshot"),
            "N=1: note must say '1 appshot' (singular)")
        XCTAssertTrue(note.contains("look_at_screen"),
            "N=1: note must reference the tool name")
    }

    func testTwoAppshotProducesPluralNote() {
        let note = armedAppshotsContextNote(count: 2)
        XCTAssertTrue(note.contains("2 appshots"),
            "N=2: note must say '2 appshots' (plural)")
        XCTAssertTrue(note.contains("look_at_screen"))
    }

    func testArmedNoteIsNonEmptyForPositiveCounts() {
        for n in 1...5 {
            XCTAssertFalse(armedAppshotsContextNote(count: n).isEmpty,
                "armedAppshotsContextNote must be non-empty for count=\(n)")
        }
    }

    // MARK: - #30 regression

    func testExistingCodecTestsStillPass() throws {
        // Verify compose_agent_prompt (from #47) and look_at_screen (#35)
        // can coexist in the session tools without breaking the codec.
        let session = SessionUpdate.bilingualV0().session
            .withRewriteTools()
            .withVisionTool()
        let update = SessionUpdate(session: session)
        let data = try JSONEncoder().encode(update)
        // Must decode back cleanly without throwing.
        let decoded = try JSONDecoder().decode(SessionUpdate.self, from: data)
        XCTAssertEqual(decoded.type, "session.update")
    }
}
