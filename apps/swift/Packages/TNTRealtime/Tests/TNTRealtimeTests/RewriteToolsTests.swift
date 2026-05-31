import XCTest
@testable import TNTRealtime

/// Golden-encode and structural tests for the M1 Rewrite tool schemas
/// (issue #47).
///
/// Acceptance criteria:
/// - Session config can include both tools with GA-correct JSON keys.
/// - compose_agent_prompt declares target, intent, raw_transcript;
///   deliver_prompt declares NO payload parameters.
/// - Factory/extension lets the composition root include these alongside
///   other tools.
/// - Existing #30 codec tests still pass; unknown frames still → .unknown.
final class RewriteToolsTests: XCTestCase {

    // MARK: - compose_agent_prompt schema

    func testComposeAgentPromptHasCorrectName() {
        XCTAssertEqual(RewriteTools.composeAgentPrompt.name, "compose_agent_prompt")
    }

    func testComposeAgentPromptTypeIsFunction() {
        XCTAssertEqual(RewriteTools.composeAgentPrompt.type, "function")
    }

    func testComposeAgentPromptDeclaresAllThreeParams() throws {
        let tool = RewriteTools.composeAgentPrompt
        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        let required = params?["required"] as? [String]
        XCTAssertEqual(
            Set(required ?? []),
            Set(["target", "intent", "raw_transcript"]),
            "compose_agent_prompt must declare exactly target, intent, raw_transcript as required"
        )
        let properties = params?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["target"])
        XCTAssertNotNil(properties?["intent"])
        XCTAssertNotNil(properties?["raw_transcript"])
        XCTAssertEqual(params?["additionalProperties"] as? Bool, false)
    }

    func testComposeAgentPromptParameterSchemaIsObject() throws {
        let data = try JSONEncoder().encode(RewriteTools.composeAgentPrompt)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
    }

    // MARK: - deliver_prompt schema

    func testDeliverPromptHasCorrectName() {
        XCTAssertEqual(RewriteTools.deliverPrompt.name, "deliver_prompt")
    }

    func testDeliverPromptTypeIsFunction() {
        XCTAssertEqual(RewriteTools.deliverPrompt.type, "function")
    }

    func testDeliverPromptDeclaresNoPayloadParameters() throws {
        let tool = RewriteTools.deliverPrompt
        let data = try JSONEncoder().encode(tool)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["parameters"] as? [String: Any]

        // deliver_prompt must have NO required params — it is a pure
        // confirmation signal; the app delivers the already-stored Rewrite.
        let required = params?["required"] as? [String]
        XCTAssertTrue(required?.isEmpty == true,
            "deliver_prompt must have no required parameters (it's a no-payload confirm signal)")

        // Properties must also be empty — no hidden payload.
        let properties = params?["properties"] as? [String: Any]
        XCTAssertTrue(properties?.isEmpty == true,
            "deliver_prompt must have no payload properties — prevents prompt injection")

        XCTAssertEqual(params?["additionalProperties"] as? Bool, false)
    }

    // MARK: - Session config with both tools

    func testSessionConfigCanIncludeBothRewriteToolsWithGAKeys() throws {
        let session = SessionUpdate.bilingualV0()
        let body = session.session.withRewriteTools()

        XCTAssertEqual(body.tools?.count, 2,
            "withRewriteTools() must add exactly 2 tools")
        XCTAssertEqual(body.toolChoice, "auto")

        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sessionJSON = json?["session"] as? [String: Any]

        // GA key must be "tools" (not "tools_list", not "tool_definitions").
        let tools = sessionJSON?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 2)

        // GA key must be "tool_choice".
        XCTAssertEqual(sessionJSON?["tool_choice"] as? String, "auto",
            "tool_choice must appear in session JSON with GA snake_case key")

        // Verify tool names are present and ordered.
        let names = tools?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["compose_agent_prompt", "deliver_prompt"])
    }

    func testWithRewriteToolsAppendsToExistingTools() throws {
        // Simulate a composition root that already has a vision tool
        // (M4 pattern) and adds Rewrite tools on top.
        let visionTool = RealtimeTool(
            name: "appshot_vision",
            description: "Capture the frontmost window",
            parameters: .object(["type": .string("object")])
        )
        var body = SessionUpdate.bilingualV0().session
        body.tools = [visionTool]
        let extended = body.withRewriteTools()

        XCTAssertEqual(extended.tools?.count, 3,
            "withRewriteTools() must append, not replace, existing tools")
        XCTAssertEqual(extended.tools?.first?.name, "appshot_vision")
        XCTAssertEqual(extended.tools?[1].name, "compose_agent_prompt")
        XCTAssertEqual(extended.tools?[2].name, "deliver_prompt")
    }

    // MARK: - RewriteTools.all

    func testAllContainsBothTools() {
        XCTAssertEqual(RewriteTools.all.count, 2)
        XCTAssertEqual(RewriteTools.all[0].name, "compose_agent_prompt")
        XCTAssertEqual(RewriteTools.all[1].name, "deliver_prompt")
    }

    // MARK: - Golden-fixture verification

    func testToolSchemaMatchesGoldenFixture() throws {
        guard let url = Bundle.module.url(
            forResource: "rewrite-tools-golden",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("rewrite-tools-golden.json fixture not found")
            return
        }
        let fixture = try JSONDecoder().decode(GoldenFixture.self, from: Data(contentsOf: url))

        // compose_agent_prompt
        let compose = fixture.compose_agent_prompt
        XCTAssertEqual(RewriteTools.composeAgentPrompt.name, compose.name)
        XCTAssertEqual(RewriteTools.composeAgentPrompt.type, compose.type)

        let composeData = try JSONEncoder().encode(RewriteTools.composeAgentPrompt)
        let composeJSON = try JSONSerialization.jsonObject(with: composeData) as? [String: Any]
        let composeParams = composeJSON?["parameters"] as? [String: Any]
        XCTAssertEqual(composeParams?["type"] as? String, compose.param_schema_type)
        let composeRequired = Set(composeParams?["required"] as? [String] ?? [])
        XCTAssertEqual(composeRequired, Set(compose.required_params))
        XCTAssertEqual(composeParams?["additionalProperties"] as? Bool, compose.additional_properties)

        // deliver_prompt
        let deliver = fixture.deliver_prompt
        XCTAssertEqual(RewriteTools.deliverPrompt.name, deliver.name)
        XCTAssertEqual(RewriteTools.deliverPrompt.type, deliver.type)

        let deliverData = try JSONEncoder().encode(RewriteTools.deliverPrompt)
        let deliverJSON = try JSONSerialization.jsonObject(with: deliverData) as? [String: Any]
        let deliverParams = deliverJSON?["parameters"] as? [String: Any]
        XCTAssertEqual(deliverParams?["type"] as? String, deliver.param_schema_type)
        let deliverRequired = Set(deliverParams?["required"] as? [String] ?? [])
        XCTAssertEqual(deliverRequired, Set(deliver.required_params))
        XCTAssertEqual(deliverParams?["additionalProperties"] as? Bool, deliver.additional_properties)
    }

    // MARK: - Regression: existing #30 tests still pass

    func testUnknownFramesStillDecodeToUnknown() throws {
        let raw = #"{"type":"response.function_call_arguments.delta","call_id":"c"}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .unknown = event else {
            XCTFail("Expected .unknown for unmodelled frame")
            return
        }
    }

    // MARK: - Fixture types

    private struct GoldenFixture: Decodable {
        struct Tool: Decodable {
            let type: String
            let name: String
            let required_params: [String]
            let param_schema_type: String
            let additional_properties: Bool
        }
        let compose_agent_prompt: Tool
        let deliver_prompt: Tool
    }
}
