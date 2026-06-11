import XCTest
@testable import TNTCognitive
import TNTCore

// MARK: - Helpers for vision tests

private func makeVisionTransport(response: String = "The error is a nil pointer dereference.") -> MockCognitiveTransport {
    MockCognitiveTransport(response: response)
}

private func makeAppshot(
    windowText: String? = "import Foundation\nlet x = 1",
    imageJPEG: Data? = nil,
    appName: String = "Cursor",
    windowTitle: String = "main.swift"
) -> Appshot {
    Appshot(imageJPEG: imageJPEG, windowText: windowText, appName: appName, windowTitle: windowTitle)
}

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

// MARK: - VisionPromptBuilder tests

/// Golden tests for `VisionPromptBuilder` (issue #123, M4b).
///
/// Acceptance criteria:
/// - text+image appshot produces text + image_url content parts.
/// - text-only appshot: image part replaced by "[image unavailable...]" note.
/// - image-only appshot (nil windowText): window text note + image part.
/// - multi-appshot: each appshot has its own block of parts.
/// - oversized-image: skipped with byte-count note.
/// - Compose request fixtures byte-identical (existing tests untouched — verified
///   by the fact that VisionPromptBuilder uses VisionCompletionsRequest, not
///   CompletionsRequest, and ChatMessage stays String-content).
final class VisionPromptBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func minimalJPEG(size: Int = 10) -> Data {
        // A minimal block of "JPEG-like" data for testing (not a real JPEG).
        Data(repeating: 0xFF, count: size)
    }

    private func buildAndInspect(
        question: String = "What's on screen?",
        appshots: [Appshot],
        model: String = "gpt-5.2"
    ) -> [VisionContentPart] {
        let req = VisionPromptBuilder.buildRequest(question: question, appshots: appshots, model: model)
        // The user message is the second (last) message.
        return req.messages.last?.content ?? []
    }

    // MARK: - Structure tests

    func testRequestHasSystemAndUserMessages() {
        let req = VisionPromptBuilder.buildRequest(
            question: "What's the error?",
            appshots: [makeAppshot()],
            model: "gpt-5.2"
        )
        XCTAssertEqual(req.messages.count, 2)
        XCTAssertEqual(req.messages[0].role, "system")
        XCTAssertEqual(req.messages[1].role, "user")
    }

    func testSystemPromptMentionsNameYourWindow() {
        let req = VisionPromptBuilder.buildRequest(
            question: "q", appshots: [makeAppshot()], model: "gpt-5.2"
        )
        let sysParts = req.messages[0].content
        guard case .text(let sys) = sysParts.first else {
            XCTFail("System message first part must be text")
            return
        }
        XCTAssertTrue(sys.contains("name the window"),
            "System prompt must instruct model to name its source window")
    }

    func testRequestUsesSuppliedModel() {
        let req = VisionPromptBuilder.buildRequest(
            question: "q", appshots: [makeAppshot()], model: "gpt-4o"
        )
        XCTAssertEqual(req.model, "gpt-4o")
    }

    // MARK: - Text + image appshot (golden)

    func testTextAndImageAppshotProducesTextAndImageParts() {
        let imageData = minimalJPEG(size: 100)
        let appshot = makeAppshot(windowText: "import Foundation", imageJPEG: imageData)
        let parts = buildAndInspect(appshots: [appshot])

        // Parts: question text, separator+label, window text, image_url
        let hasImagePart = parts.contains {
            if case .imageURL = $0 { return true }
            return false
        }
        let hasTextPart = parts.contains {
            if case .text(let t) = $0 { return t.contains("import Foundation") }
            return false
        }
        XCTAssertTrue(hasImagePart, "Text+image appshot must include an image_url part")
        XCTAssertTrue(hasTextPart, "Text+image appshot must include a text part with window text")
    }

    func testImagePartIsBase64DataURI() throws {
        let imageData = minimalJPEG(size: 100)
        let appshot = Appshot(imageJPEG: imageData, windowText: nil, appName: "Xcode", windowTitle: "main.swift")
        let parts = buildAndInspect(appshots: [appshot])

        // Find the imageURL part and verify its base64 content.
        var foundBase64: String?
        for part in parts {
            if case .imageURL(let b64) = part {
                foundBase64 = b64
                break
            }
        }
        XCTAssertNotNil(foundBase64, "Image part must be present in parts")
        XCTAssertEqual(foundBase64, imageData.base64EncodedString(),
            "Image part base64 must exactly match the original image data encoded as base64")
    }

    // MARK: - Text-only appshot (nil image)

    func testTextOnlyAppshotSkipsImagePart() {
        let appshot = makeAppshot(windowText: "some text", imageJPEG: nil)
        let parts = buildAndInspect(appshots: [appshot])

        let hasImagePart = parts.contains {
            if case .imageURL = $0 { return true }
            return false
        }
        XCTAssertFalse(hasImagePart, "Text-only appshot must not include an image_url part")

        let hasImageNote = parts.contains {
            if case .text(let t) = $0 { return t.contains("image unavailable") }
            return false
        }
        XCTAssertTrue(hasImageNote, "Text-only appshot must include an '[image unavailable...]' note")
    }

    func testTextOnlyAppshotIncludesWindowText() {
        let appshot = makeAppshot(windowText: "the real content", imageJPEG: nil)
        let parts = buildAndInspect(appshots: [appshot])

        let hasWindowText = parts.contains {
            if case .text(let t) = $0 { return t.contains("the real content") }
            return false
        }
        XCTAssertTrue(hasWindowText, "Text-only appshot must still include window text")
    }

    // MARK: - Image-only appshot (nil windowText)

    func testImageOnlyAppshotIncludesImageAndTextNote() {
        let imageData = minimalJPEG(size: 50)
        let appshot = makeAppshot(windowText: nil, imageJPEG: imageData)
        let parts = buildAndInspect(appshots: [appshot])

        let hasImagePart = parts.contains {
            if case .imageURL = $0 { return true }
            return false
        }
        XCTAssertTrue(hasImagePart, "Image-only appshot must include the image_url part")

        let hasTextNote = parts.contains {
            if case .text(let t) = $0 { return t.contains("no window text available") }
            return false
        }
        XCTAssertTrue(hasTextNote, "Image-only appshot must include a 'no window text' note")
    }

    // MARK: - Multi-appshot

    func testMultiAppshotEachHasItsOwnBlock() {
        let a1 = makeAppshot(windowText: "first window text", appName: "Cursor")
        let a2 = makeAppshot(windowText: "second window text", appName: "Chrome")
        let parts = buildAndInspect(appshots: [a1, a2])

        let hasFirst = parts.contains {
            if case .text(let t) = $0 { return t.contains("first window text") }
            return false
        }
        let hasSecond = parts.contains {
            if case .text(let t) = $0 { return t.contains("second window text") }
            return false
        }
        XCTAssertTrue(hasFirst, "First appshot's window text must appear in parts")
        XCTAssertTrue(hasSecond, "Second appshot's window text must appear in parts")

        // Both source labels present.
        let hasCursor = parts.contains {
            if case .text(let t) = $0 { return t.contains("Cursor") }
            return false
        }
        let hasChrome = parts.contains {
            if case .text(let t) = $0 { return t.contains("Chrome") }
            return false
        }
        XCTAssertTrue(hasCursor, "Source label for Cursor appshot must appear")
        XCTAssertTrue(hasChrome, "Source label for Chrome appshot must appear")
    }

    // MARK: - Oversized image skipped

    func testOversizedImageProducesNote() {
        let limit = VisionPromptBuilder.imageByteLimit
        let oversized = Data(repeating: 0xAB, count: limit + 1)
        let appshot = makeAppshot(windowText: "some text", imageJPEG: oversized)
        let parts = buildAndInspect(appshots: [appshot])

        let hasImagePart = parts.contains {
            if case .imageURL = $0 { return true }
            return false
        }
        XCTAssertFalse(hasImagePart, "Oversized image must not produce an image_url part")

        let hasNote = parts.contains {
            if case .text(let t) = $0 { return t.contains("exceeds limit") || t.contains("image unavailable") }
            return false
        }
        XCTAssertTrue(hasNote, "Oversized image must produce an explanatory note")
    }

    // MARK: - Both-nil appshot skipped entirely

    func testBothNilAppshotSkippedWithNote() {
        let appshot = Appshot(imageJPEG: nil, windowText: nil, appName: "Unknown", windowTitle: "")
        let parts = buildAndInspect(appshots: [appshot])

        let hasSkipNote = parts.contains {
            if case .text(let t) = $0 { return t.contains("no content available") || t.contains("skipped") }
            return false
        }
        XCTAssertTrue(hasSkipNote, "All-nil appshot must be skipped with a note")

        let hasImagePart = parts.contains {
            if case .imageURL = $0 { return true }
            return false
        }
        XCTAssertFalse(hasImagePart, "All-nil appshot must not produce an image_url part")
    }

    // MARK: - Empty appshot list

    func testEmptyAppshotListProducesNote() {
        let parts = buildAndInspect(appshots: [])

        let hasNote = parts.contains {
            if case .text(let t) = $0 { return t.contains("No screen sources") }
            return false
        }
        XCTAssertTrue(hasNote, "Empty appshot list must produce a 'no sources' note")
    }

    // MARK: - Question included

    func testQuestionAppearsInUserContent() {
        let parts = buildAndInspect(
            question: "What is causing this build error?",
            appshots: [makeAppshot()]
        )
        let hasQuestion = parts.contains {
            if case .text(let t) = $0 { return t.contains("What is causing this build error?") }
            return false
        }
        XCTAssertTrue(hasQuestion, "The user's question must appear in user content parts")
    }

    // MARK: - Golden JSON stability

    func testIdenticalInputsProduceIdenticalJSON() throws {
        let imageData = minimalJPEG(size: 50)
        let appshot = makeAppshot(windowText: "stable text", imageJPEG: imageData)
        let r1 = VisionPromptBuilder.buildRequest(question: "q?", appshots: [appshot], model: "gpt-5.2")
        let r2 = VisionPromptBuilder.buildRequest(question: "q?", appshots: [appshot], model: "gpt-5.2")
        let enc = JSONEncoder()
        XCTAssertEqual(try enc.encode(r1), try enc.encode(r2),
            "Identical inputs must produce byte-identical VisionCompletionsRequest JSON")
    }

    // MARK: - Compose fixture byte-identity (ChatMessage stays String-content)

    func testComposeRequestFixturesUnchanged() {
        // VisionPromptBuilder uses VisionChatMessage (content = [VisionContentPart]).
        // ChatMessage keeps content: String. They are different types; compose
        // requests are unaffected. Prove it by checking ChatMessage content is still String.
        let messages = RewritePromptBuilder.buildMessages(
            target: .claudeCode, intent: "test", raw: "test raw", capture: .empty
        )
        for msg in messages {
            // ChatMessage.content is a String — if this compiles, the type is unchanged.
            let content: String = msg.content
            XCTAssertFalse(content.isEmpty)
        }
        XCTAssertEqual(messages.count, 8,
            "Compose request fixture message count must be unchanged (1 sys + 6 few-shot + 1 user)")
    }
}

// MARK: - LocalOpenAIEngine vision route tests

/// Tests for `LocalOpenAIEngine.answerAboutScreen` (issue #123, M4b).
///
/// Acceptance criteria:
/// - Stubbed transport returns response text → extracted correctly.
/// - Transport error surfaces as thrown error (not swallowed).
/// - ZDR header set on vision requests.
/// - Correct endpoint used.
final class LocalOpenAIEngineVisionTests: XCTestCase {

    private func makeEngine(
        response: String = "The screen shows a nil pointer error on line 42.",
        statusCode: Int = 200
    ) -> (LocalOpenAIEngine, MockCognitiveTransport) {
        let transport = MockCognitiveTransport(response: response)
        let engine = LocalOpenAIEngine(apiKey: "sk-vision-test", model: "gpt-5.2", transport: transport)
        return (engine, transport)
    }

    func testAnswerAboutScreenReturnsModelOutput() async throws {
        let (engine, _) = makeEngine(response: "The error is on line 42.")
        let appshot = Appshot(windowText: "error: nil dereference", appName: "Xcode")
        let result = try await engine.answerAboutScreen(
            question: "What's the error?",
            appshots: [appshot]
        )
        XCTAssertEqual(result, "The error is on line 42.")
    }

    func testAnswerAboutScreenUsesCorrectEndpoint() async throws {
        let (engine, transport) = makeEngine()
        _ = try? await engine.answerAboutScreen(
            question: "q", appshots: [Appshot(windowText: "x", appName: "App")]
        )
        XCTAssertEqual(transport.lastRequest?.url, LocalOpenAIEngine.completionsURL)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
    }

    func testAnswerAboutScreenSetsZDRHeader() async throws {
        let (engine, transport) = makeEngine()
        _ = try? await engine.answerAboutScreen(
            question: "q", appshots: [Appshot(windowText: "x", appName: "App")]
        )
        let zdr = transport.lastRequest?.value(forHTTPHeaderField: "OpenAI-ZDR")
        XCTAssertEqual(zdr, "true", "Vision request must set OpenAI-ZDR: true (ADR-0004)")
    }

    func testAnswerAboutScreenSetsAuthorizationHeader() async throws {
        let (engine, transport) = makeEngine()
        _ = try? await engine.answerAboutScreen(
            question: "q", appshots: [Appshot(windowText: "x", appName: "App")]
        )
        let auth = transport.lastRequest?.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(auth, "Bearer sk-vision-test")
    }

    func testTransportErrorSurfacesAsThrown() async throws {
        final class FailTransport: CognitiveTransport, @unchecked Sendable {
            func send(request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(.notConnectedToInternet)
            }
        }
        let engine = LocalOpenAIEngine(apiKey: "sk-test", transport: FailTransport())
        do {
            _ = try await engine.answerAboutScreen(question: "q", appshots: [])
            XCTFail("Expected transport error to be thrown")
        } catch {
            // Expected — transport error propagates; VisionOrchestrator (#126) catches it.
            XCTAssertTrue(error is URLError)
        }
    }

    func testHTTPErrorSurfacesForVisionPath() async throws {
        final class ErrorTransport: CognitiveTransport, @unchecked Sendable {
            func send(request: URLRequest) async throws -> (Data, URLResponse) {
                let data = Data("{\"error\":\"quota_exceeded\"}".utf8)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            }
        }
        let engine = LocalOpenAIEngine(apiKey: "sk-test", transport: ErrorTransport())
        do {
            _ = try await engine.answerAboutScreen(question: "q", appshots: [])
            XCTFail("Expected httpError to be thrown")
        } catch LocalOpenAIEngineError.httpError(let code, _) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("Expected LocalOpenAIEngineError.httpError, got \(error)")
        }
    }

    func testVisionRequestBodyIsValidJSON() async throws {
        let (engine, transport) = makeEngine()
        let appshot = Appshot(windowText: "content", appName: "Xcode", windowTitle: "App.swift")
        _ = try? await engine.answerAboutScreen(question: "What's shown?", appshots: [appshot])

        guard let body = transport.lastRequest?.httpBody else {
            XCTFail("Request body must not be nil")
            return
        }
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNotNil(obj, "Vision request body must be valid JSON")
        XCTAssertEqual(obj?["model"] as? String, "gpt-5.2")
        let messages = obj?["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertGreaterThan(messages?.count ?? 0, 0)
    }
}
