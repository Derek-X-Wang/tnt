import XCTest
@testable import TNTCognitive
import TNTCore

// MARK: - Mock transport

/// Test transport that records the last request and returns a canned
/// OpenAI chat/completions response. No live network in tests.
final class MockCognitiveTransport: CognitiveTransport, @unchecked Sendable {
    var lastRequest: URLRequest?
    var response: String

    init(response: String = "Add a unit test to the rate-limit middleware.") {
        self.response = response
    }

    func send(request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let json = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "\(response)"
              }
            }
          ]
        }
        """
        let data = Data(json.utf8)
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, httpResponse)
    }
}

// MARK: - Prompt builder tests

/// Golden tests for `RewritePromptBuilder` — pure input → deterministic
/// messages array, no network.
///
/// Acceptance criteria (issue #32):
/// - Messages match the structure of the checked-in golden fixtures.
/// - `rate-limit` preserved verbatim in the code-switch test.
/// - system + few-shot + user message count and roles correct.
final class RewritePromptBuilderTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Input: Decodable {
            let target_key: String
            let target_display_name: String
            let intent: String
            let raw: String
            let capture_app: String?
            let capture_project: String?
        }
        struct Expectations: Decodable {
            let message_count: Int
            let first_role: String
            let last_role: String
            let last_content_contains_target: String?
            let last_content_contains_raw: String?
            let last_content_contains_project: String?
            let last_content_contains_app: String?
            let system_message_contains: [String]?
            let technical_term_preserved: String?
            let technical_term_preserved_2: String?
        }
        let name: String
        let input: Input
        let expectations: Expectations
    }

    func testPureEnglishFixture() throws {
        try replayFixture(named: "pure-en-request")
    }

    func testPureMandarinFixture() throws {
        try replayFixture(named: "pure-zh-request")
    }

    func testCodeSwitchedFixture() throws {
        try replayFixture(named: "code-switch-request")
    }

    /// The code-switch case is the acceptance criterion from the issue.
    /// Explicitly assert `rate-limit` survives verbatim in the user message.
    func testCodeSwitchPreservesRateLimitVerbatim() {
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode,
            intent: "per-IP rate limiting",
            raw: "这个 function should rate-limit 每个 IP，max 10次 per second，用 sliding window 算法。",
            capture: CaptureSet(appName: "Cursor", project: ProjectRef(name: "tnt"))
        )
        let userMessage = messages.last!.content
        XCTAssertTrue(
            userMessage.contains("rate-limit"),
            "Technical term 'rate-limit' must appear verbatim in the user message — not translated or de-hyphenated"
        )
    }

    func testMessageStructureIsSystemThenFewShotThenUser() {
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode,
            intent: "test intent",
            raw: "test raw",
            capture: .empty
        )
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last?.role, "user")
        // system + 6 few-shot (3 user/assistant pairs) + 1 user = 8
        XCTAssertEqual(messages.count, 8,
            "Expected 8 messages: 1 system + 6 few-shot + 1 user")
    }

    func testSystemPromptMentionsRewriteAndEnglish() {
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode,
            intent: "test",
            raw: "test",
            capture: .empty
        )
        let system = messages.first!.content
        XCTAssertTrue(system.localizedCaseInsensitiveContains("Rewrite"),
            "System prompt must mention 'Rewrite'")
        XCTAssertTrue(system.localizedCaseInsensitiveContains("English"),
            "System prompt must mention 'English' output for Worker Agents")
        XCTAssertTrue(system.localizedCaseInsensitiveContains("technical terms"),
            "System prompt must mention technical term preservation")
    }

    func testUserMessageIncludesCaptureSetBullets() {
        let capture = CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "func rateLimitMiddleware()",
            project: ProjectRef(name: "tnt", path: "/Users/dev/tnt")
        )
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode,
            intent: "test",
            raw: "test raw",
            capture: capture
        )
        let userMsg = messages.last!.content
        XCTAssertTrue(userMsg.contains("Cursor"), "User message must include app name")
        XCTAssertTrue(userMsg.contains("tnt"), "User message must include project name")
        XCTAssertTrue(userMsg.contains("rateLimitMiddleware"), "User message must include selection")
    }

    func testEmptyCaptureSetOmitsBullets() {
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode,
            intent: "test",
            raw: "test",
            capture: .empty
        )
        let userMsg = messages.last!.content
        XCTAssertTrue(userMsg.contains("(none)"),
            "Empty capture set should produce '(none)' context marker")
    }

    // MARK: - Fixture replay

    private func replayFixture(named name: String) throws {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("Fixture \(name).json not found")
            return
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let capture = CaptureSet(
            appName: fixture.input.capture_app,
            project: fixture.input.capture_project.map { ProjectRef(name: $0) }
        )
        let target = AgentRef(
            key: fixture.input.target_key,
            displayName: fixture.input.target_display_name
        )
        let messages = RewritePromptBuilder.buildMessages(
            target: target,
            intent: fixture.input.intent,
            raw: fixture.input.raw,
            capture: capture
        )
        let exp = fixture.expectations

        XCTAssertEqual(messages.count, exp.message_count,
            "[\(name)] message count mismatch")
        XCTAssertEqual(messages.first?.role, exp.first_role,
            "[\(name)] first message role")
        XCTAssertEqual(messages.last?.role, exp.last_role,
            "[\(name)] last message role")

        let lastContent = messages.last?.content ?? ""
        if let targetStr = exp.last_content_contains_target {
            XCTAssertTrue(lastContent.contains(targetStr),
                "[\(name)] user message must contain target: \(targetStr)")
        }
        if let rawStr = exp.last_content_contains_raw {
            XCTAssertTrue(lastContent.contains(rawStr),
                "[\(name)] user message must contain raw fragment: \(rawStr)")
        }
        if let projStr = exp.last_content_contains_project {
            XCTAssertTrue(lastContent.contains(projStr),
                "[\(name)] user message must contain project: \(projStr)")
        }
        if let appStr = exp.last_content_contains_app {
            XCTAssertTrue(lastContent.contains(appStr),
                "[\(name)] user message must contain app: \(appStr)")
        }
        if let terms = exp.system_message_contains {
            let sysContent = messages.first?.content ?? ""
            for term in terms {
                XCTAssertTrue(sysContent.localizedCaseInsensitiveContains(term),
                    "[\(name)] system prompt must contain: \(term)")
            }
        }
        if let tech = exp.technical_term_preserved {
            XCTAssertTrue(lastContent.contains(tech),
                "[\(name)] technical term '\(tech)' must be verbatim in user message")
        }
        if let tech2 = exp.technical_term_preserved_2 {
            XCTAssertTrue(lastContent.contains(tech2),
                "[\(name)] technical term '\(tech2)' must be verbatim in user message")
        }
    }
}

// MARK: - LocalOpenAIEngine tests

/// Tests for `LocalOpenAIEngine` — replays a recorded OpenAI response
/// via `MockCognitiveTransport`. No live network.
final class LocalOpenAIEngineTests: XCTestCase {

    func testComposeReturnsModelOutput() async throws {
        let transport = MockCognitiveTransport(
            response: "Add a unit test to the rate-limit middleware."
        )
        let engine = LocalOpenAIEngine(
            apiKey: "sk-test",
            model: "gpt-5.2",
            transport: transport
        )
        let result = try await engine.compose(
            target: .claudeCode,
            intent: "add unit test",
            raw: "add a unit test to the rate-limit middleware",
            capture: .empty
        )
        XCTAssertEqual(result, "Add a unit test to the rate-limit middleware.")
    }

    func testRequestUsesCorrectModelAndEndpoint() async throws {
        let transport = MockCognitiveTransport()
        let engine = LocalOpenAIEngine(apiKey: "sk-test", model: "gpt-4o", transport: transport)
        _ = try? await engine.compose(
            target: .claudeCode, intent: "test", raw: "test", capture: .empty
        )
        guard let request = transport.lastRequest else {
            XCTFail("No request captured")
            return
        }
        // Verify the request targets the completions endpoint.
        XCTAssertEqual(request.url, LocalOpenAIEngine.completionsURL)
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testRequestSetsAuthorizationHeader() async throws {
        let transport = MockCognitiveTransport()
        let engine = LocalOpenAIEngine(apiKey: "sk-test-key", transport: transport)
        _ = try? await engine.compose(
            target: .claudeCode, intent: "test", raw: "test", capture: .empty
        )
        let auth = transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-test-key",
            "Authorization header must be Bearer + BYOK key")
    }

    func testRequestSetsZDRHeader() async throws {
        // Per ADR-0004: every Cognitive Engine call must set the OpenAI ZDR
        // header at the application layer (separate from the org/project-level
        // ZDR for GA Realtime — see ADR-0004 amendment).
        let transport = MockCognitiveTransport()
        let engine = LocalOpenAIEngine(apiKey: "sk-test", transport: transport)
        _ = try? await engine.compose(
            target: .claudeCode, intent: "test", raw: "test", capture: .empty
        )
        let zdr = transport.lastRequest?.value(forHTTPHeaderField: "OpenAI-ZDR")
        XCTAssertEqual(zdr, "true",
            "Every Cognitive Engine request must set OpenAI-ZDR: true (ADR-0004)")
    }

    func testRequestBodyContainsModelAndMessages() async throws {
        let transport = MockCognitiveTransport()
        let engine = LocalOpenAIEngine(apiKey: "sk-test", model: "gpt-5.2", transport: transport)
        _ = try? await engine.compose(
            target: .claudeCode, intent: "test", raw: "test input", capture: .empty
        )
        guard let body = transport.lastRequest?.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Request body must be valid JSON")
            return
        }
        XCTAssertEqual(json["model"] as? String, "gpt-5.2")
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertGreaterThan(messages?.count ?? 0, 0)

        // Verify the user message contains the raw transcript.
        let lastMessage = messages?.last
        let content = lastMessage?["content"] as? String
        XCTAssertTrue(content?.contains("test input") == true,
            "Request body must include the raw transcript in the user message")
    }

    func testHTTPErrorSurfacesAsLocalOpenAIEngineError() async throws {
        final class ErrorTransport: CognitiveTransport, @unchecked Sendable {
            func send(request: URLRequest) async throws -> (Data, URLResponse) {
                let data = Data("{\"error\":\"rate_limit\"}".utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        }
        let engine = LocalOpenAIEngine(apiKey: "sk-test", transport: ErrorTransport())
        do {
            _ = try await engine.compose(
                target: .claudeCode, intent: "test", raw: "test", capture: .empty
            )
            XCTFail("Expected httpError to be thrown")
        } catch LocalOpenAIEngineError.httpError(let code, _) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("Expected LocalOpenAIEngineError.httpError, got \(error)")
        }
    }

    func testEmptyChoicesThrowsEmptyResponse() async throws {
        final class EmptyTransport: CognitiveTransport, @unchecked Sendable {
            func send(request: URLRequest) async throws -> (Data, URLResponse) {
                let data = Data("{\"choices\":[]}".utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        }
        let engine = LocalOpenAIEngine(apiKey: "sk-test", transport: EmptyTransport())
        do {
            _ = try await engine.compose(
                target: .claudeCode, intent: "test", raw: "test", capture: .empty
            )
            XCTFail("Expected emptyResponse to be thrown")
        } catch LocalOpenAIEngineError.emptyResponse {
            // correct
        } catch {
            XCTFail("Expected emptyResponse, got \(error)")
        }
    }
}
