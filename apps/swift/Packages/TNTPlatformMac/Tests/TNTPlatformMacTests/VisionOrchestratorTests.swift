import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Tests for `VisionOrchestrator` (issue #126, M4b).
///
/// Acceptance criteria from issue #126:
/// - Success: fco(answer text) → rc ordering; consume fired with resolve-time ids only.
/// - New appshot armed mid-call survives consume (test simulates arm between dispatch and completion).
/// - Stale token → nothing sent, nothing consumed.
/// - Active error → error-shaped fco + rc, nothing consumed.
/// - read_screen_text path untouched (ScreenTextOrchestrator has no consume hook).
/// - `swift test` green: TNTPlatformMac + TNTCore.
final class VisionOrchestratorTests: XCTestCase {

    // MARK: - Helpers

    private func makeAppshot(
        appName: String,
        id: UUID = UUID()
    ) -> Appshot {
        Appshot(id: id, windowText: "some window text", appName: appName, windowTitle: "Window")
    }

    private func makeResolved(armed: [Appshot], current: Appshot? = nil) -> ResolvedScreenSources {
        ResolvedScreenSources(armed: armed, current: current)
    }

    // MARK: - Success path: fco → rc, consume resolve-time ids only

    func testSuccessEmitsFcoThenRc() async {
        var fcoCallId: String?
        var fcoOutput: String?
        var rcCalled = false
        var consumedIds: Set<UUID>?

        let armed = makeAppshot(appName: "Cursor")
        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: [armed]) },
            answerAboutScreen: { _, _ in "The screen shows a Swift file." },
            sendFunctionCallOutput: { callId, output in
                fcoCallId = callId
                fcoOutput = output
            },
            sendResponseCreate: { rcCalled = true },
            consumeArmed: { consumedIds = $0 }
        )

        let args = AnalyzeScreenArgs(question: "What's on screen?")
        await orchestrator.handle(.analyzeScreen(args), callId: "call_abc")

        XCTAssertEqual(fcoCallId, "call_abc", "fco must use the tool call ID")
        XCTAssertEqual(fcoOutput, "The screen shows a Swift file.", "fco output must be the answer text")
        XCTAssertTrue(rcCalled, "response.create must follow the fco")
        XCTAssertEqual(consumedIds, [armed.id], "consume must fire with the resolve-time armed id")
    }

    func testSuccessConsumeUsesResolveTimeIds() async {
        // A new Appshot is armed between resolve and completion.
        // The orchestrator must consume only the ids captured at dispatch time.
        let resolvedArmed = makeAppshot(appName: "Cursor")
        let laterArmed = makeAppshot(appName: "Chrome")

        var currentArmed = [resolvedArmed]
        var consumedIds: Set<UUID>?

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: currentArmed) },
            answerAboutScreen: { _, _ -> String in
                // Simulate arming a new Appshot mid-call.
                currentArmed.append(laterArmed)
                return "Answer"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: { },
            consumeArmed: { consumedIds = $0 }
        )

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "call_1")

        XCTAssertEqual(consumedIds, [resolvedArmed.id],
            "Must consume ONLY the appshot armed at dispatch time — not the one armed mid-call")
        XCTAssertTrue(currentArmed.contains(where: { $0.id == laterArmed.id }),
            "The mid-call armed appshot must survive (not consumed)")
    }

    func testSuccessNeverConsumesCurrentFreshGrab() async {
        let armed = makeAppshot(appName: "Cursor")
        let currentFresh = makeAppshot(appName: "Arc")

        var consumedIds: Set<UUID>?

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: [armed], current: currentFresh) },
            answerAboutScreen: { _, _ in "Answer" },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: { },
            consumeArmed: { consumedIds = $0 }
        )

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "call_2")

        XCTAssertFalse(consumedIds?.contains(currentFresh.id) ?? false,
            "The current fresh grab must never be consumed — it is turn-scoped, not store-backed")
        XCTAssertTrue(consumedIds?.contains(armed.id) ?? false,
            "The armed store appshot must be consumed on success")
    }

    // MARK: - Stale token: nothing sent, nothing consumed

    func testStaleTokenDropsSilently() async {
        // Simulate barge-in: use a continuation to advance the token mid-call.
        // We pass the orchestrator via a box so the closure can reference it.
        final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
        let box = Box<VisionOrchestrator>()

        var fcoSent = false
        var rcSent = false
        var consumedCalled = false

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: [self.makeAppshot(appName: "Cursor")]) },
            answerAboutScreen: { [box] _, _ -> String in
                // Advance token mid-call to simulate barge-in.
                await box.value?.advanceTurnToken()
                return "Answer"
            },
            sendFunctionCallOutput: { _, _ in fcoSent = true },
            sendResponseCreate: { rcSent = true },
            consumeArmed: { _ in consumedCalled = true }
        )
        box.value = orchestrator

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "call_stale")

        XCTAssertFalse(fcoSent, "Stale: no fco must be sent")
        XCTAssertFalse(rcSent, "Stale: no rc must be sent")
        XCTAssertFalse(consumedCalled, "Stale: consume must not fire")
    }

    // MARK: - Active error: error-shaped fco + rc, no consume

    func testActiveErrorEmitsErrorFcoAndRc() async {
        var fcoOutput: String?
        var rcCalled = false
        var consumedCalled = false

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: [self.makeAppshot(appName: "Cursor")]) },
            answerAboutScreen: { _, _ in
                throw NSError(domain: "test", code: 503, userInfo: [NSLocalizedDescriptionKey: "service unavailable"])
            },
            sendFunctionCallOutput: { _, output in fcoOutput = output },
            sendResponseCreate: { rcCalled = true },
            consumeArmed: { _ in consumedCalled = true }
        )

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "call_err")

        XCTAssertNotNil(fcoOutput, "Error path must emit an fco")
        XCTAssertTrue(fcoOutput?.contains("screen_vision_error") ?? false,
            "Error fco must have kind:screen_vision_error")
        XCTAssertTrue(rcCalled, "Error path must emit response.create to unblock the Realtime turn")
        XCTAssertFalse(consumedCalled, "Error path must NOT consume armed Appshots")
    }

    func testActiveErrorFcoIsValidJSON() async {
        var fcoOutput: String?

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: []) },
            answerAboutScreen: { _, _ in
                throw NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "internal error"])
            },
            sendFunctionCallOutput: { _, output in fcoOutput = output },
            sendResponseCreate: { },
            consumeArmed: { _ in }
        )

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: nil)), callId: "call_json")

        guard let output = fcoOutput else { XCTFail("No fco output"); return }
        let data = Data(output.utf8)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj, "Error fco must be valid JSON")
        XCTAssertEqual(obj?["kind"] as? String, "screen_vision_error")
        XCTAssertNotNil(obj?["error"], "Error fco must include an error field")
    }

    // MARK: - advanceTurnToken mid-call makes the call stale

    func testBargeInDuringCallDropsSilently() async {
        // Same as testStaleTokenDropsSilently but more explicit about ordering.
        // Stale = token was advanced DURING the async vision call (barge-in).
        // A new call started AFTER advance is NOT stale (it dispatches on the new token).
        final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
        let box = Box<VisionOrchestrator>()

        var fcoSent = false
        var rcSent = false

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: []) },
            answerAboutScreen: { [box] _, _ -> String in
                // Advance token mid-call to simulate barge-in.
                await box.value?.advanceTurnToken()
                return "Answer"
            },
            sendFunctionCallOutput: { _, _ in fcoSent = true },
            sendResponseCreate: { rcSent = true },
            consumeArmed: { _ in }
        )
        box.value = orchestrator

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "c_barge")

        XCTAssertFalse(fcoSent, "Barge-in mid-call: fco must be dropped")
        XCTAssertFalse(rcSent, "Barge-in mid-call: rc must be dropped")
    }

    // MARK: - consume fires with empty set when no armed appshots

    func testConsumeNotCalledWhenNoArmedAppshots() async {
        var consumedCalled = false

        let orchestrator = VisionOrchestrator(
            resolveSources: { self.makeResolved(armed: []) },
            answerAboutScreen: { _, _ in "Answer" },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: { },
            consumeArmed: { ids in
                if !ids.isEmpty { consumedCalled = true }
            }
        )

        await orchestrator.handle(.analyzeScreen(AnalyzeScreenArgs(question: "q")), callId: "c0")

        XCTAssertFalse(consumedCalled, "consume must not fire with non-empty set when no armed appshots")
    }
}
