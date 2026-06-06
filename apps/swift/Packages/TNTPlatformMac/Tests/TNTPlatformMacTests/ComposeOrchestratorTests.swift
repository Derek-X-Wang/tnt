import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Unit tests for `ComposeOrchestrator` (issue #79).
///
/// Acceptance criteria:
/// - On a .compose decision: invokes compose closure with mapped AgentRef/intent/raw/capture,
///   then emits function_call_output + response.create via injected hooks.
/// - Emits .confirmationProduced(pendingRewrite:) only on the subsequent confirm response.done;
///   never synchronously on compose return.
/// - A compose result arriving after the turn-generation token advanced is dropped.
/// - Stores/exposes the pending Rewrite for the deliver path.
/// - Imports only TNTCore; unit-tested with stub closures (no network/hardware).
final class ComposeOrchestratorTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a stub orchestrator where compose always returns the given rewrite.
    private func makeOrchestrator(
        rewrite: String = "Cleaned prompt.",
        capture: CaptureSet = .empty
    ) -> (ComposeOrchestrator, [String]) {
        var log: [String] = []
        let orchestrator = ComposeOrchestrator(
            compose: { agentRef, intent, raw, _ in
                log.append("compose:\(agentRef.key):\(intent)")
                return rewrite
            },
            sendFunctionCallOutput: { callId, output in
                log.append("fco:\(callId):\(output.prefix(20))")
            },
            sendResponseCreate: {
                log.append("rc")
            }
        )
        return (orchestrator, log)
    }

    // MARK: - On .compose decision: invokes compose closure and emits hooks

    func testComposeSendsHooksAfterCompletion() async throws {
        var log: [String] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, intent, _, _ in
                log.append("compose:\(intent)")
                return "Clean: \(intent)"
            },
            sendFunctionCallOutput: { callId, output in
                log.append("fco:\(callId)")
            },
            sendResponseCreate: {
                log.append("rc")
            }
        )

        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "add a test", rawTranscript: "add test pls")
        let capture = CaptureSet(appName: "Cursor", windowTitle: nil, selectedText: nil, project: nil)
        let decision = ToolCallDecision.compose(args)

        await orchestrator.handleDecision(decision, callId: "call-1", capture: capture)

        XCTAssertTrue(log.contains("compose:add a test"),
            "compose closure must be invoked with the intent from args")
        XCTAssertTrue(log.contains(where: { $0.hasPrefix("fco:call-1") }),
            "function_call_output must be sent after compose completes")
        XCTAssertTrue(log.contains("rc"),
            "response.create must be sent after compose completes")
    }

    func testComposeSendsFunctionCallOutputBeforeResponseCreate() async throws {
        var log: [String] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "rewrite" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "add a test", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)
        let fcoIdx = log.firstIndex(of: "fco")
        let rcIdx = log.firstIndex(of: "rc")
        XCTAssertNotNil(fcoIdx)
        XCTAssertNotNil(rcIdx)
        XCTAssertLessThan(fcoIdx!, rcIdx!,
            "function_call_output must be sent before response.create")
    }

    func testComposeMapsCursorTargetToAgentRef() async throws {
        var receivedAgentRef: AgentRef?
        let orchestrator = ComposeOrchestrator(
            compose: { agentRef, _, _, _ in
                receivedAgentRef = agentRef
                return "rewrite"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        let args = ComposeAgentPromptArgs(target: "cursor", intent: "do something", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)
        XCTAssertEqual(receivedAgentRef?.key, "cursor",
            "compose must be called with the AgentRef matching the target string")
    }

    func testComposePassesCaptureSetToComposeClosure() async throws {
        var receivedCapture: CaptureSet?
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, capture in
                receivedCapture = capture
                return "rewrite"
            },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        let capture = CaptureSet(appName: "Xcode", windowTitle: "main.swift", selectedText: "let x", project: nil)
        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "refactor", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: capture)
        XCTAssertEqual(receivedCapture, capture)
    }

    // MARK: - .confirmationProduced only on subsequent response.done, not synchronously

    func testConfirmationProducedIsNotEmittedSynchronouslyOnComposeReturn() async throws {
        var events: [ComposeOrchestratorEvent] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "rewrite" },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {},
            onEvent: { events.append($0) }
        )
        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "add test", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)
        // After handleDecision returns, confirmationProduced must NOT have been emitted yet.
        XCTAssertFalse(events.contains(where: {
            if case .confirmationProduced = $0 { return true }
            return false
        }), ".confirmationProduced must NOT fire synchronously on compose return")
    }

    func testConfirmationProducedEmittedOnSubsequentResponseDone() async throws {
        var events: [ComposeOrchestratorEvent] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "Cleaned prompt." },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {},
            onEvent: { events.append($0) }
        )
        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "add test", rawTranscript: nil)
        // handleDecision starts the compose round-trip
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)
        // Simulate the confirm response.done arriving
        orchestrator.handleResponseDone(responseId: "resp-confirm-1", status: "completed")
        // Now confirmationProduced should have fired
        let hasConfirmation = events.contains(where: {
            if case .confirmationProduced(let rewrite) = $0 {
                return rewrite == "Cleaned prompt."
            }
            return false
        })
        XCTAssertTrue(hasConfirmation,
            ".confirmationProduced must fire on the subsequent response.done after compose")
    }

    // MARK: - Stores pending Rewrite for deliver path

    func testPendingRewriteIsStoredAfterCompose() async throws {
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "My pending rewrite." },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "add test", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)
        XCTAssertEqual(orchestrator.pendingRewrite, "My pending rewrite.",
            "pendingRewrite must be stored after compose completes")
    }

    func testPendingRewriteIsNilBeforeAnyCompose() {
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "x" },
            sendFunctionCallOutput: { _, _ in },
            sendResponseCreate: {}
        )
        XCTAssertNil(orchestrator.pendingRewrite,
            "pendingRewrite must be nil before any compose")
    }

    // MARK: - Stale-compose guard: dropped after turn-generation token advances

    func testStaleComposeResultIsDropped() async throws {
        var functionCallOutputCount = 0
        var responseCreateCount = 0

        // We simulate the stale scenario by calling advanceTurnToken() INSIDE
        // the compose closure — i.e. "while compose is running, a barge-in occurs".
        var orchestratorRef: ComposeOrchestrator?
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in
                // Advance the token mid-compose to simulate a barge-in.
                orchestratorRef?.advanceTurnToken()
                return "stale result"
            },
            sendFunctionCallOutput: { _, _ in functionCallOutputCount += 1 },
            sendResponseCreate: { responseCreateCount += 1 }
        )
        orchestratorRef = orchestrator

        let args = ComposeAgentPromptArgs(target: "claude-code", intent: "turn 1", rawTranscript: nil)
        await orchestrator.handleDecision(.compose(args), callId: "c1", capture: .empty)

        // The token advanced during compose, so the result is stale — no fco/rc.
        XCTAssertEqual(functionCallOutputCount, 0,
            "Stale compose result must not send function_call_output")
        XCTAssertEqual(responseCreateCount, 0,
            "Stale compose result must not send response.create")
    }

    // MARK: - .deliver and .ignore decisions are no-ops for orchestrator

    func testDeliverDecisionIsNoOp() async throws {
        var log: [String] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "x" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        await orchestrator.handleDecision(.deliver, callId: "c1", capture: .empty)
        XCTAssertTrue(log.isEmpty,
            ".deliver decision must not invoke compose or send hooks")
    }

    func testIgnoreDecisionIsNoOp() async throws {
        var log: [String] = []
        let orchestrator = ComposeOrchestrator(
            compose: { _, _, _, _ in "x" },
            sendFunctionCallOutput: { _, _ in log.append("fco") },
            sendResponseCreate: { log.append("rc") }
        )
        await orchestrator.handleDecision(.ignore, callId: "c1", capture: .empty)
        XCTAssertTrue(log.isEmpty,
            ".ignore decision must not invoke compose or send hooks")
    }
}
