import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Unit tests for `ScreenTextOrchestrator`, `InFlightToolRoute`, and
/// the `ReadScreenArgs` decode path in `ToolCallDispatch` (issue #105, M4a).
///
/// Acceptance criteria:
/// - Classify: read_screen_text → .readScreen (question decoded; malformed soft);
///   unknown names still .ignore; compose/deliver unchanged.
/// - fco emitted with the snapshot string, then response.create; ordering asserted.
/// - Stale token: barge-in drops the late snapshot — nothing sent.
/// - Armed Appshots untouched by a read (no consume hook exists).
/// - InFlightToolRoute transition tests incl. route-clears-after-suppressed-done,
///   answer-done-reaches-flow, compose/screen isolation.
final class ScreenTextOrchestratorTests: XCTestCase {

    // MARK: - Helpers

    /// Appshot with minimal fields for tests.
    private func makeAppshot(appName: String = "Cursor", windowText: String = "Hello world") -> Appshot {
        Appshot(
            windowText: windowText,
            appName: appName,
            windowTitle: "main.swift"
        )
    }

    /// Build a ScreenTextOrchestrator where the log captures ordered calls.
    private func makeOrchestrator(
        sources: [Appshot] = [],
        snapshotResult: String = "{\"kind\":\"screen_text_snapshot\"}"
    ) -> (ScreenTextOrchestrator, [String]) {
        var log: [String] = []
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { sources },
            buildSnapshot: { question, appshots in
                log.append("build:\(question ?? "nil"):\(appshots.count)")
                return snapshotResult
            },
            sendFunctionCallOutput: { callId, json in
                log.append("fco:\(callId):\(json.prefix(20))")
            },
            sendResponseCreate: {
                log.append("rc")
            }
        )
        return (orchestrator, log)
    }

    // =========================================================================
    // MARK: - Part 1: ReadScreenArgs decode (ToolCallDispatch)
    // =========================================================================

    func testReadScreenArgsDecodesFull() {
        let args = ReadScreenArgs.decode(from: #"{"question":"what is on screen?"}"#)
        XCTAssertEqual(args.question, "what is on screen?")
    }

    func testReadScreenArgsMalformedJSONReturnNilQuestion() {
        let args = ReadScreenArgs.decode(from: "{{bad json")
        XCTAssertNil(args.question,
            "Malformed JSON must yield ReadScreenArgs with nil question, not crash")
    }

    func testReadScreenArgsMissingQuestionFieldReturnsNilQuestion() {
        let args = ReadScreenArgs.decode(from: #"{"other_field":"ignored"}"#)
        XCTAssertNil(args.question,
            "Missing 'question' key must yield nil question")
    }

    func testReadScreenArgsEmptyStringReturnsNilQuestion() {
        let args = ReadScreenArgs.decode(from: "")
        XCTAssertNil(args.question)
    }

    func testClassifyReadScreenTextReturnsReadScreen() {
        let decision = classifyToolCall(
            name: "read_screen_text",
            argumentsJSON: #"{"question":"anything visible?"}"#
        )
        guard case .readScreen(let args) = decision else {
            XCTFail("Expected .readScreen, got \(decision)")
            return
        }
        XCTAssertEqual(args.question, "anything visible?")
    }

    func testClassifyReadScreenTextMalformedStillReturnsReadScreen() {
        // Even malformed args must yield .readScreen (nil question) — turn must proceed.
        let decision = classifyToolCall(name: "read_screen_text", argumentsJSON: "{{bad")
        guard case .readScreen(let args) = decision else {
            XCTFail("Expected .readScreen even for malformed JSON, got \(decision)")
            return
        }
        XCTAssertNil(args.question)
    }

    func testClassifyComposeUnchangedByReadScreenAddition() {
        let json = #"{"target":"claude-code","intent":"do it","raw_transcript":"do it"}"#
        let decision = classifyToolCall(name: "compose_agent_prompt", argumentsJSON: json)
        guard case .compose(let args) = decision else {
            XCTFail("Expected .compose, got \(decision)")
            return
        }
        XCTAssertEqual(args.target, "claude-code")
    }

    func testClassifyDeliverUnchanged() {
        let decision = classifyToolCall(name: "deliver_prompt", argumentsJSON: "{}")
        guard case .deliver = decision else {
            XCTFail("Expected .deliver, got \(decision)")
            return
        }
    }

    func testClassifyUnknownNameStillIgnore() {
        let decision = classifyToolCall(name: "analyze_screen", argumentsJSON: "{}")
        guard case .ignore = decision else {
            XCTFail("Expected .ignore for unknown tool, got \(decision)")
            return
        }
    }

    // =========================================================================
    // MARK: - Part 2: ScreenTextOrchestrator — fco + rc ordering
    // =========================================================================

    func testFcoEmittedBeforeResponseCreate() async {
        var log: [String] = []
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "{}" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        let args = ReadScreenArgs(question: "What's visible?")
        await orchestrator.handleDecision(.readScreen(args), callId: "call-1")
        let fcoIdx = log.firstIndex(of: "fco")
        let rcIdx  = log.firstIndex(of: "rc")
        XCTAssertNotNil(fcoIdx, "function_call_output must be sent")
        XCTAssertNotNil(rcIdx,  "response.create must be sent")
        XCTAssertLessThan(fcoIdx!, rcIdx!,
            "function_call_output must precede response.create")
    }

    func testFcoCarriesSnapshotJSON() async {
        var capturedOutput: String?
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in #"{"kind":"screen_text_snapshot"}"# },
            sendFunctionCallOutput: { _, json in capturedOutput = json },
            sendResponseCreate: {}
        )
        let args = ReadScreenArgs(question: nil)
        await orchestrator.handleDecision(.readScreen(args), callId: "c1")
        XCTAssertEqual(capturedOutput, #"{"kind":"screen_text_snapshot"}"#,
            "fco output must be the exact string returned by buildSnapshot")
    }

    func testFcoCarriesCorrectCallId() async {
        var capturedCallId: String?
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "{}" },
            sendFunctionCallOutput: { callId, _ in capturedCallId = callId },
            sendResponseCreate: {}
        )
        await orchestrator.handleDecision(.readScreen(ReadScreenArgs(question: nil)), callId: "my-call-99")
        XCTAssertEqual(capturedCallId, "my-call-99")
    }

    func testBuildSnapshotReceivesQuestionFromArgs() async {
        var receivedQuestion: String?
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { question, _ in
                receivedQuestion = question
                return "{}"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        let args = ReadScreenArgs(question: "Is there a dialog open?")
        await orchestrator.handleDecision(.readScreen(args), callId: "c1")
        XCTAssertEqual(receivedQuestion, "Is there a dialog open?")
    }

    func testBuildSnapshotReceivesResolvedSources() async {
        let appshots = [makeAppshot(appName: "Cursor"), makeAppshot(appName: "Chrome")]
        var receivedCount: Int?
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { appshots },
            buildSnapshot: { _, sources in
                receivedCount = sources.count
                return "{}"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        await orchestrator.handleDecision(.readScreen(ReadScreenArgs(question: nil)), callId: "c1")
        XCTAssertEqual(receivedCount, 2, "buildSnapshot must receive the resolved sources")
    }

    // MARK: - Non-.readScreen decisions are no-ops

    func testComposeDecisionIsNoOp() async {
        var log: [String] = []
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "x" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        let composeArgs = ComposeAgentPromptArgs(target: "claude-code", intent: "test", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(composeArgs), callId: "c1")
        XCTAssertTrue(log.isEmpty, ".compose must be a no-op for ScreenTextOrchestrator")
    }

    func testDeliverDecisionIsNoOp() async {
        var log: [String] = []
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "x" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        await orchestrator.handleDecision(.deliver, callId: "c1")
        XCTAssertTrue(log.isEmpty, ".deliver must be a no-op for ScreenTextOrchestrator")
    }

    func testIgnoreDecisionIsNoOp() async {
        var log: [String] = []
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "x" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        await orchestrator.handleDecision(.ignore, callId: "c1")
        XCTAssertTrue(log.isEmpty, ".ignore must be a no-op for ScreenTextOrchestrator")
    }

    // =========================================================================
    // MARK: - Part 3: Stale-token guard
    // =========================================================================

    func testStaleTokenDropsSnapshot() async {
        var fcoCount = 0
        var rcCount  = 0

        // Simulate barge-in: advance the token inside resolveSources (which runs
        // before the guard check, so the dispatch token will be stale when we check).
        var orchestratorRef: ScreenTextOrchestrator?
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: {
                // Mid-execution barge-in: advance the token.
                orchestratorRef?.advanceTurnToken()
                return []
            },
            buildSnapshot: { _, _ in "{}" },
            sendFunctionCallOutput: { _, _ in fcoCount += 1 },
            sendResponseCreate: { rcCount += 1 }
        )
        orchestratorRef = orchestrator

        await orchestrator.handleDecision(.readScreen(ReadScreenArgs(question: nil)), callId: "c1")

        XCTAssertEqual(fcoCount, 0, "Stale result must not send function_call_output")
        XCTAssertEqual(rcCount,  0, "Stale result must not send response.create")
    }

    func testFreshTokenAfterAdvanceSendsNormally() async {
        // After advancing the token, a new decision must still fire normally.
        var rcCount = 0
        let orchestrator = ScreenTextOrchestrator(
            resolveSources: { [] },
            buildSnapshot: { _, _ in "{}" },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: { rcCount += 1 }
        )
        orchestrator.advanceTurnToken()
        await orchestrator.handleDecision(.readScreen(ReadScreenArgs(question: nil)), callId: "c1")
        XCTAssertEqual(rcCount, 1, "Fresh token must still send response.create")
    }

    // =========================================================================
    // MARK: - Part 4: Armed Appshots untouched
    // =========================================================================

    func testArmedAppshotsNotConsumedByScreenRead() async {
        // The resolveSources closure returns the armed appshots for the snapshot,
        // but does NOT clear them. We verify the injected closure is not a "consume"
        // hook — i.e. its side effects are the responsibility of the store layer,
        // and ScreenTextOrchestrator has no consume hook.
        //
        // This is structural: ScreenTextOrchestrator has no `consumeArmedAppshots`
        // parameter — the absence of that parameter is the contract.
        let appshot = makeAppshot(appName: "Cursor")
        var store = ArmedAppshotStore()
        store.arm(appshot)

        var buildCallCount = 0
        let orchestrator = ScreenTextOrchestrator(
            // resolveSources returns the armed Appshots; store is NOT mutated
            resolveSources: { store.appshots },
            buildSnapshot: { _, sources in
                buildCallCount += 1
                return "{}"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )

        await orchestrator.handleDecision(.readScreen(ReadScreenArgs(question: nil)), callId: "c1")

        // Armed Appshots survive the screen read.
        XCTAssertEqual(store.count, 1, "Armed Appshots must not be consumed by a Tier-1 screen read")
        XCTAssertEqual(buildCallCount, 1, "buildSnapshot must have been called")
    }

    // =========================================================================
    // MARK: - Part 5: InFlightToolRoute transitions
    // =========================================================================

    func testInitialRouteIsNone() {
        let route = InFlightToolRoute.none
        XCTAssertEqual(route, .none)
        XCTAssertFalse(route.suppressesNextDone)
    }

    func testScreenRouteSupressesNextDone() {
        let route = InFlightToolRoute.screenToolSuppressingFunctionDone
        XCTAssertTrue(route.suppressesNextDone,
            "screenToolSuppressingFunctionDone must suppress the next done")
    }

    func testComposeRouteDoesNotSuppressDone() {
        let route = InFlightToolRoute.compose
        XCTAssertFalse(route.suppressesNextDone,
            "compose route must not suppress done (ComposeOrchestrator handles it)")
    }

    func testMarkFunctionDoneSuppressedClearsScreenRoute() {
        var route = InFlightToolRoute.screenToolSuppressingFunctionDone
        route.markFunctionDoneSuppressed()
        XCTAssertEqual(route, .none,
            "After suppression, route must be .none so spoken-answer done reaches VoiceTurnFlow")
    }

    func testMarkFunctionDoneSuppressedNoOpOnNone() {
        var route = InFlightToolRoute.none
        route.markFunctionDoneSuppressed()
        XCTAssertEqual(route, .none, "markFunctionDoneSuppressed on .none must be a no-op")
    }

    func testMarkFunctionDoneSuppressedNoOpOnCompose() {
        var route = InFlightToolRoute.compose
        route.markFunctionDoneSuppressed()
        XCTAssertEqual(route, .compose,
            "markFunctionDoneSuppressed on .compose must be a no-op")
    }

    func testResetClearsAnyRoute() {
        var routeA = InFlightToolRoute.compose
        routeA.reset()
        XCTAssertEqual(routeA, .none)

        var routeB = InFlightToolRoute.screenToolSuppressingFunctionDone
        routeB.reset()
        XCTAssertEqual(routeB, .none)
    }

    func testRouteLifecycle_screenTool() {
        // Full lifecycle: none → screen → (fco done suppressed) → none → (spoken done flows)
        var route = InFlightToolRoute.none

        // Tool call arrives: controller sets route to screen mode.
        route = .screenToolSuppressingFunctionDone
        XCTAssertTrue(route.suppressesNextDone, "Screen route suppresses fco response.done")

        // First response.done arrives (synthetic fco response): suppress + advance.
        XCTAssertTrue(route.suppressesNextDone)
        route.markFunctionDoneSuppressed()
        XCTAssertEqual(route, .none, "After fco done suppressed, route clears")

        // Second response.done arrives (spoken answer): reaches VoiceTurnFlow.
        XCTAssertFalse(route.suppressesNextDone, "Spoken-answer done must not be suppressed")
    }

    func testRouteLifecycle_compose() {
        // Compose path: none → compose → (answer done handled by ComposeOrchestrator) → none
        var route = InFlightToolRoute.none
        route = .compose
        XCTAssertFalse(route.suppressesNextDone,
            "Compose route: response.done goes to ComposeOrchestrator, not suppressed by route")

        // After turn ends, reset.
        route.reset()
        XCTAssertEqual(route, .none)
    }

    func testComposeAndScreenRoutesDoNotInterfere() {
        // Setting compose route does not affect screen route behavior and vice versa.
        var routeA = InFlightToolRoute.compose
        var routeB = InFlightToolRoute.screenToolSuppressingFunctionDone

        routeB.markFunctionDoneSuppressed()
        XCTAssertEqual(routeA, .compose, "routeA must be unaffected by routeB mutation")
        XCTAssertEqual(routeB, .none)
    }

    func testMissingDoneFrame_screenRouteRemainsUntilReset() {
        // If the fco response.done never arrives (e.g. dropped by server),
        // the route stays in .screenToolSuppressingFunctionDone until barge-in
        // calls reset(). This ensures no phantom suppression of future turns.
        var route = InFlightToolRoute.screenToolSuppressingFunctionDone

        // Barge-in: new turn → reset.
        route.reset()
        XCTAssertEqual(route, .none,
            "Barge-in reset must clear any stale screen route")
    }

    func testReorderedDoneFrames_suppressionIsIdempotent() {
        // If two done events arrive (e.g. server sends duplicate), calling
        // markFunctionDoneSuppressed twice must not corrupt state.
        var route = InFlightToolRoute.screenToolSuppressingFunctionDone
        route.markFunctionDoneSuppressed()  // first call: .none
        route.markFunctionDoneSuppressed()  // second call: no-op
        XCTAssertEqual(route, .none, "Double suppression must remain .none")
    }
}
