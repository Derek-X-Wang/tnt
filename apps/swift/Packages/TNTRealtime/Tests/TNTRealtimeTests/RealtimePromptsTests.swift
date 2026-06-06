import XCTest
@testable import TNTRealtime

/// The v0 system prompt must name both M1 Rewrite tools so the Realtime model
/// has behavioural guidance to call them (the per-tool `description` strings
/// alone proved too thin). Locked here so a prompt edit can't silently drop the
/// tool guidance (issue #50).
final class RealtimePromptsTests: XCTestCase {

    func testV0SystemNamesComposeTool() {
        XCTAssertTrue(RealtimePrompts.v0System.contains("compose_agent_prompt"))
    }

    func testV0SystemNamesDeliverTool() {
        XCTAssertTrue(RealtimePrompts.v0System.contains("deliver_prompt"))
    }

    func testV0SystemRequiresAffirmationBeforeDeliver() {
        // The prompt must instruct the model not to deliver without affirmation —
        // the safety contract the no-payload deliver_prompt design relies on.
        XCTAssertTrue(RealtimePrompts.v0System.contains("affirm"))
    }
}
