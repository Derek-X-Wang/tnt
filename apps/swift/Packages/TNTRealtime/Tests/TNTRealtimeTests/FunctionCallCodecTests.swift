import XCTest
@testable import TNTRealtime

/// Codec tests for the GA Realtime function-call event shapes (issue #30).
///
/// Acceptance criteria verified:
/// - `SessionConfig` encodes `tools` + `tool_choice` with GA-correct
///   snake_case JSON keys.
/// - Decoding `response.function_call_arguments.done` yields the
///   `functionCallArgumentsDone` case with callId, name, argumentsJSON intact.
/// - Encoding `ConversationItemCreateFunctionOutput` produces a valid
///   `conversation.item.create` with `type: "function_call_output"`,
///   `call_id`, and `output`.
/// - Existing codec tests still pass; unknown frames still → `.unknown`.
final class FunctionCallCodecTests: XCTestCase {

    // MARK: - SessionConfig tools + tool_choice encoding

    func testSessionConfigEncodesToolsArrayWithGAKeys() throws {
        let tool = RealtimeTool(
            name: "compose_agent_prompt",
            description: "Rewrite a Voice Turn transcript into a clean Worker Agent prompt",
            parameters: JSONValue.schema(
                type: "object",
                properties: [
                    "target": .object(["type": .string("string")]),
                    "intent": .object(["type": .string("string")]),
                    "raw_transcript": .object(["type": .string("string")])
                ],
                required: ["target", "intent", "raw_transcript"],
                additionalProperties: false
            )
        )

        let body = SessionUpdate.Body(
            audio: SessionUpdate.Audio(
                input: SessionUpdate.AudioInput(),
                output: SessionUpdate.AudioOutput(voice: "marin")
            ),
            tools: [tool],
            toolChoice: "auto"
        )
        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let session = json?["session"] as? [String: Any]

        // tools array must be present with GA key "tools"
        let tools = session?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1, "Expected exactly 1 tool in the tools array")

        let toolJSON = tools?.first
        XCTAssertEqual(toolJSON?["type"] as? String, "function",
            "GA requires tool type = \"function\"")
        XCTAssertEqual(toolJSON?["name"] as? String, "compose_agent_prompt")
        XCTAssertNotNil(toolJSON?["description"])
        XCTAssertNotNil(toolJSON?["parameters"])

        // tool_choice must use the GA snake_case key
        XCTAssertEqual(session?["tool_choice"] as? String, "auto",
            "tool_choice must encode with GA snake_case key \"tool_choice\"")
    }

    func testSessionConfigOmitsToolsWhenNil() throws {
        let body = SessionUpdate.Body(
            audio: SessionUpdate.Audio(
                input: SessionUpdate.AudioInput(),
                output: SessionUpdate.AudioOutput(voice: "marin")
            )
            // tools and toolChoice default to nil
        )
        let update = SessionUpdate(session: body)
        let data = try JSONEncoder().encode(update)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let session = json?["session"] as? [String: Any]

        // tools and tool_choice must be absent when nil — not present as
        // explicit nulls, which the server may reject.
        XCTAssertNil(session?["tools"],
            "tools must not appear in session JSON when nil")
        XCTAssertNil(session?["tool_choice"],
            "tool_choice must not appear in session JSON when nil")
    }

    func testRealtimeToolTypeIsAlwaysFunction() {
        let tool = RealtimeTool(
            name: "appshot_vision",
            description: "Capture the frontmost window (Appshot) and answer a visual question",
            parameters: .object(["type": .string("object")])
        )
        XCTAssertEqual(tool.type, "function",
            "RealtimeTool.type must always be \"function\" per GA spec")
    }

    // MARK: - functionCallArgumentsDone decoding

    func testDecodesFunctionCallArgumentsDoneFromGAFixture() throws {
        // Real GA `response.function_call_arguments.done` frame shape.
        let raw = """
        {
          "type": "response.function_call_arguments.done",
          "call_id": "call_abc123",
          "name": "compose_agent_prompt",
          "arguments": "{\\"target\\":\\"claude-code\\",\\"intent\\":\\"add unit test\\"}"
        }
        """
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .functionCallArgumentsDone(let callId, let name, let args) = event else {
            XCTFail("Expected functionCallArgumentsDone, got \(event)")
            return
        }
        XCTAssertEqual(callId, "call_abc123")
        XCTAssertEqual(name, "compose_agent_prompt")
        // argumentsJSON is the raw arguments string — not further decoded here.
        XCTAssertTrue(args.contains("claude-code"),
            "argumentsJSON should contain the encoded target value")
    }

    func testUnknownFrameStillFallsToUnknown() throws {
        let raw = #"{"type":"response.function_call_arguments.delta","call_id":"c","delta":"{"}"#
        let event = try RealtimeEventDecoder.decode(from: Data(raw.utf8))
        guard case .unknown(let type) = event else {
            XCTFail("Expected unknown for unmodelled frame, got \(event)")
            return
        }
        XCTAssertEqual(type, "response.function_call_arguments.delta")
    }

    // MARK: - conversationItemCreateFunctionOutput encoding

    func testConversationItemCreateFunctionOutputGoldenEncode() throws {
        let event = ConversationItemCreateFunctionOutput(
            callId: "call_abc123",
            output: "I'll send the rewrite to Claude Code."
        )
        let data = try JSONEncoder().encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Top-level type must be "conversation.item.create"
        XCTAssertEqual(json?["type"] as? String, "conversation.item.create",
            "Top-level type must be conversation.item.create")

        let item = json?["item"] as? [String: Any]
        XCTAssertNotNil(item, "item key must be present")
        XCTAssertEqual(item?["type"] as? String, "function_call_output",
            "item.type must be function_call_output")
        XCTAssertEqual(item?["call_id"] as? String, "call_abc123",
            "item.call_id must match (GA snake_case key)")
        XCTAssertEqual(item?["output"] as? String, "I'll send the rewrite to Claude Code.",
            "item.output must carry the tool result string")
    }

    func testConversationItemCreateFunctionOutputRoundTrips() throws {
        let original = ConversationItemCreateFunctionOutput(
            callId: "call_xyz",
            output: "Done."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            ConversationItemCreateFunctionOutput.self, from: data
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.type, "conversation.item.create")
        XCTAssertEqual(decoded.item.type, "function_call_output")
        XCTAssertEqual(decoded.item.callId, "call_xyz")
    }

    // MARK: - JSONValue codec

    func testJSONValueSchemaHelperProducesValidSchema() throws {
        let schema = JSONValue.schema(
            type: "object",
            properties: ["name": .object(["type": .string("string")])],
            required: ["name"],
            additionalProperties: false
        )
        let data = try JSONEncoder().encode(schema)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["type"] as? String, "object")
        XCTAssertNotNil(json?["properties"])
        XCTAssertEqual(json?["required"] as? [String], ["name"])
        XCTAssertEqual(json?["additionalProperties"] as? Bool, false)
    }

    func testJSONValueRoundTripsAllTypes() throws {
        let values: [JSONValue] = [
            .string("hello"),
            .number(42.0),
            .bool(true),
            .null,
            .object(["k": .string("v")]),
            .array([.string("a"), .number(1.0)])
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(decoded, value, "JSONValue round-trip failed for \(value)")
        }
    }
}
