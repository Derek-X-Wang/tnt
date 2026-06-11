import XCTest
@testable import TNTRealtime

/// Tests for `desiredSessionConfig` (issue #106, M4a).
///
/// Acceptance criteria:
/// - N=0: tools = rewrite pair + read_screen_text; instructions carry no armed note.
/// - N=2: armed note present with correct count; tools unchanged.
/// - Byte-identical encode for identical inputs (golden).
/// - Existing `bilingualV0`/`withRewriteTools` behavior untouched.
/// - `swift test` green for TNTRealtime.
final class DesiredSessionConfigTests: XCTestCase {

    // MARK: - N=0: no armed Appshots

    func testN0HasRewriteToolsAndScreenTool() throws {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let tools = config.session.tools
        XCTAssertEqual(tools?.count, 3,
            "N=0: must have compose_agent_prompt + deliver_prompt + read_screen_text")
        XCTAssertEqual(tools?[0].name, "compose_agent_prompt")
        XCTAssertEqual(tools?[1].name, "deliver_prompt")
        XCTAssertEqual(tools?[2].name, "read_screen_text")
    }

    func testN0InstructionsHaveNoArmedNote() throws {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let instructions = config.session.instructions ?? ""
        XCTAssertFalse(instructions.contains("appshot"),
            "N=0: instructions must not contain armed-context note")
        XCTAssertFalse(instructions.contains("read_screen_text"),
            "N=0: instructions must not mention read_screen_text tool in the note")
    }

    func testN0ToolChoiceIsAuto() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        XCTAssertEqual(config.session.toolChoice, "auto")
    }

    // MARK: - N=2: two armed Appshots

    func testN2HasArmedNoteInInstructions() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 2)
        let instructions = config.session.instructions ?? ""
        XCTAssertTrue(instructions.contains("2 appshots"),
            "N=2: instructions must contain '2 appshots' from the armed-context note")
        XCTAssertTrue(instructions.contains("read_screen_text"),
            "N=2: instructions must reference read_screen_text in the armed note")
    }

    func testN2ToolsUnchanged() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 2)
        let tools = config.session.tools
        XCTAssertEqual(tools?.count, 3,
            "N=2: tools must remain compose + deliver + read_screen_text (unchanged)")
        XCTAssertEqual(tools?[0].name, "compose_agent_prompt")
        XCTAssertEqual(tools?[1].name, "deliver_prompt")
        XCTAssertEqual(tools?[2].name, "read_screen_text")
    }

    func testN1HasSingularArmedNote() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 1)
        let instructions = config.session.instructions ?? ""
        XCTAssertTrue(instructions.contains("1 appshot"),
            "N=1: instructions must contain '1 appshot' (singular)")
    }

    // MARK: - Byte-identical for identical inputs (golden)

    func testIdenticalInputsProduceIdenticalJSON() throws {
        let c1 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let c2 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let d1 = try encoder.encode(c1)
        let d2 = try encoder.encode(c2)
        XCTAssertEqual(d1, d2, "Identical inputs must produce byte-identical JSON")
    }

    func testDifferentArmedCountsProduceDifferentJSON() throws {
        let c0 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let c2 = desiredSessionConfig(voice: "marin", armedAppshotCount: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let d0 = try encoder.encode(c0)
        let d2 = try encoder.encode(c2)
        XCTAssertNotEqual(d0, d2,
            "Different armedAppshotCount must produce different JSON (instructions differ)")
    }

    func testDifferentVoicesProduceDifferentJSON() throws {
        let c1 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let c2 = desiredSessionConfig(voice: "alloy", armedAppshotCount: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let d1 = try encoder.encode(c1)
        let d2 = try encoder.encode(c2)
        XCTAssertNotEqual(d1, d2, "Different voice must produce different JSON")
    }

    // MARK: - Type correctness

    func testConfigTypeIsSessionUpdate() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        XCTAssertEqual(config.type, "session.update")
    }

    func testConfigSessionTypeIsRealtime() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        XCTAssertEqual(config.session.type, "realtime")
    }

    func testConfigOutputModalitiesIsAudio() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        XCTAssertEqual(config.session.outputModalities, ["audio"])
    }

    func testConfigVoiceIsPreserved() {
        let config = desiredSessionConfig(voice: "alloy", armedAppshotCount: 0)
        XCTAssertEqual(config.session.audio.output.voice, "alloy")
    }

    // MARK: - Existing bilingualV0 / withRewriteTools behavior untouched

    func testBilingualV0StillWorks() {
        let base = SessionUpdate.bilingualV0()
        XCTAssertEqual(base.type, "session.update")
        XCTAssertEqual(base.session.audio.output.voice, "marin")
        XCTAssertNil(base.session.tools, "bilingualV0 alone must have no tools")
    }

    func testWithRewriteToolsStillWorks() {
        let body = SessionUpdate.bilingualV0().session.withRewriteTools()
        XCTAssertEqual(body.tools?.count, 2)
        XCTAssertEqual(body.tools?[0].name, "compose_agent_prompt")
        XCTAssertEqual(body.tools?[1].name, "deliver_prompt")
    }

    func testWithScreenToolsStillWorks() {
        let body = SessionUpdate.bilingualV0().session.withScreenTools()
        XCTAssertEqual(body.tools?.count, 1)
        XCTAssertEqual(body.tools?[0].name, "read_screen_text")
    }

    // MARK: - visionEnabled=false: byte-identical to M4a (golden)

    func testVisionDisabledProducesSameToolsAsM4a() {
        // visionEnabled defaults to false — must be byte-identical to M4a call sites.
        let c0 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0)
        let c1 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: false)
        let tools0 = c0.session.tools ?? []
        let tools1 = c1.session.tools ?? []
        XCTAssertEqual(tools0.map(\.name), tools1.map(\.name),
            "visionEnabled:false must produce identical tool list to M4a (no visionEnabled arg)")
    }

    func testVisionEnabledAppendsAnalyzeScreenAfterReadScreenText() {
        let config = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: true)
        let tools = config.session.tools ?? []
        XCTAssertEqual(tools.count, 4,
            "visionEnabled:true must add analyze_screen: compose + deliver + read_screen_text + analyze_screen")
        XCTAssertEqual(tools[0].name, "compose_agent_prompt")
        XCTAssertEqual(tools[1].name, "deliver_prompt")
        XCTAssertEqual(tools[2].name, "read_screen_text")
        XCTAssertEqual(tools[3].name, "analyze_screen",
            "analyze_screen must be appended AFTER read_screen_text (escalation tier)")
    }

    func testVisionEnabledGoldenIdentical() throws {
        // Two identical calls with visionEnabled:true must produce byte-identical JSON.
        let c1 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: true)
        let c2 = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(c1), try encoder.encode(c2),
            "Identical inputs (visionEnabled:true) must produce byte-identical JSON")
    }

    func testVisionEnabledDiffersFromVisionDisabled() throws {
        let cNo = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: false)
        let cYes = desiredSessionConfig(voice: "marin", armedAppshotCount: 0, visionEnabled: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertNotEqual(try encoder.encode(cNo), try encoder.encode(cYes),
            "visionEnabled:true and visionEnabled:false must produce different JSON (extra tool)")
    }

    func testWithVisionToolsStillWorks() {
        let body = SessionUpdate.bilingualV0().session.withVisionTools()
        XCTAssertEqual(body.tools?.count, 1)
        XCTAssertEqual(body.tools?[0].name, "analyze_screen")
    }
}
