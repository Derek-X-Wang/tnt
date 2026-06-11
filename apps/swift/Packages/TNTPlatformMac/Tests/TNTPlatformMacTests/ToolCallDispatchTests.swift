import XCTest
@testable import TNTPlatformMac

/// Unit tests for `classifyToolCall` and `ComposeAgentPromptArgs` (issue #78).
///
/// Acceptance criteria:
/// - ComposeAgentPromptArgs decodes `{target, intent, raw_transcript}` via snake_case CodingKeys.
/// - Malformed or missing-required JSON → decode returns nil (no throw escapes); classify handles without crash.
/// - classifyToolCall("compose_agent_prompt", …) → .compose(args)
/// - classifyToolCall("deliver_prompt", "{}") → .deliver
/// - Any other name → .ignore
/// - Module imports only TNTCore.
final class ToolCallDispatchTests: XCTestCase {

    // MARK: - ComposeAgentPromptArgs decoding

    func testDecodesFullPayload() throws {
        let json = """
        {"target":"claude-code","intent":"add a unit test","raw_transcript":"add unit test please"}
        """
        let args = try XCTUnwrap(ComposeAgentPromptArgs.decode(from: json))
        XCTAssertEqual(args.target, "claude-code")
        XCTAssertEqual(args.intent, "add a unit test")
        XCTAssertEqual(args.rawTranscript, "add unit test please")
    }

    func testDecodesMissingOptionalRawTranscript() throws {
        // raw_transcript missing — if it's optional, should still succeed
        let json = """
        {"target":"cursor","intent":"refactor this function"}
        """
        let args = try XCTUnwrap(ComposeAgentPromptArgs.decode(from: json))
        XCTAssertEqual(args.target, "cursor")
        XCTAssertEqual(args.intent, "refactor this function")
    }

    func testMalformedJSONReturnsNil() {
        // Not valid JSON
        let args = ComposeAgentPromptArgs.decode(from: "not json at all {{")
        XCTAssertNil(args, "Malformed JSON must return nil, not throw")
    }

    func testMissingRequiredFieldTargetReturnsNil() {
        // Missing required 'target' field
        let json = """
        {"intent":"add a test","raw_transcript":"add test"}
        """
        let args = ComposeAgentPromptArgs.decode(from: json)
        XCTAssertNil(args, "Missing required 'target' must return nil")
    }

    func testMissingRequiredFieldIntentReturnsNil() {
        // Missing required 'intent' field
        let json = """
        {"target":"claude-code","raw_transcript":"add test"}
        """
        let args = ComposeAgentPromptArgs.decode(from: json)
        XCTAssertNil(args, "Missing required 'intent' must return nil")
    }

    func testEmptyStringJSONReturnsNil() {
        let args = ComposeAgentPromptArgs.decode(from: "")
        XCTAssertNil(args, "Empty string must return nil")
    }

    func testEmptyObjectJSONReturnsNil() {
        let args = ComposeAgentPromptArgs.decode(from: "{}")
        XCTAssertNil(args, "Empty object (missing required fields) must return nil")
    }

    // MARK: - classifyToolCall: compose_agent_prompt

    func testClassifyComposeAgentPromptReturnsCompose() throws {
        let json = """
        {"target":"claude-code","intent":"add a unit test","raw_transcript":"add unit test please"}
        """
        let decision = classifyToolCall(name: "compose_agent_prompt", argumentsJSON: json)
        guard case .compose(let args) = decision else {
            XCTFail("Expected .compose, got \(decision)")
            return
        }
        XCTAssertEqual(args.target, "claude-code")
        XCTAssertEqual(args.intent, "add a unit test")
        XCTAssertEqual(args.rawTranscript, "add unit test please")
    }

    func testClassifyComposeWithMalformedJSONReturnsIgnore() {
        // Malformed JSON for compose_agent_prompt → soft fail → .ignore (not crash)
        let decision = classifyToolCall(name: "compose_agent_prompt", argumentsJSON: "{{bad}}")
        guard case .ignore = decision else {
            XCTFail("Expected .ignore for malformed JSON on compose_agent_prompt, got \(decision)")
            return
        }
    }

    // MARK: - classifyToolCall: deliver_prompt

    func testClassifyDeliverPromptReturnsDeliver() {
        let decision = classifyToolCall(name: "deliver_prompt", argumentsJSON: "{}")
        guard case .deliver = decision else {
            XCTFail("Expected .deliver, got \(decision)")
            return
        }
    }

    func testClassifyDeliverPromptWithAnyArgsReturnsDeliver() {
        // deliver_prompt is zero-arg; extra fields should still return .deliver
        let decision = classifyToolCall(name: "deliver_prompt", argumentsJSON: "{\"extra\":true}")
        guard case .deliver = decision else {
            XCTFail("Expected .deliver for deliver_prompt regardless of args, got \(decision)")
            return
        }
    }

    // MARK: - classifyToolCall: unknown names

    func testClassifyUnknownNameReturnsIgnore() {
        let decision = classifyToolCall(name: "some_future_tool", argumentsJSON: "{}")
        guard case .ignore = decision else {
            XCTFail("Expected .ignore for unknown tool name, got \(decision)")
            return
        }
    }

    func testClassifyEmptyNameReturnsIgnore() {
        let decision = classifyToolCall(name: "", argumentsJSON: "{}")
        guard case .ignore = decision else {
            XCTFail("Expected .ignore for empty tool name, got \(decision)")
            return
        }
    }

    func testClassifyUnknownFutureToolReturnsIgnore() {
        // A genuinely unknown tool name — should always be .ignore.
        // (Replaces the stale "get_appshot" fixture — that name no longer exists.)
        let decision = classifyToolCall(name: "some_future_m5_tool", argumentsJSON: "{}")
        guard case .ignore = decision else {
            XCTFail("Expected .ignore for unknown future tool, got \(decision)")
            return
        }
    }
}
