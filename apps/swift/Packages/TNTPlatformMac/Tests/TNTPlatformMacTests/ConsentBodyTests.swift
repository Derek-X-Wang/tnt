import XCTest
@testable import TNTPlatformMac

/// String-content tests for the first-run consent body.
///
/// Per the M0/S4 acceptance criterion, every outbound data category must
/// be enumerated in plain language before the User clicks Continue. The
/// list is the *contract* of the v0 privacy posture — drift here means
/// drift in what TNT promises, so each required topic gets its own test.
final class ConsentBodyTests: XCTestCase {

    private let body = ConsentBody.default

    func testHasExactlySevenRequiredSections() {
        let expected: Set<ConsentBody.SectionID> = Set(ConsentBody.SectionID.allCases)
        XCTAssertEqual(expected.count, 7, "M0/S4 contract: exactly seven privacy categories.")
        XCTAssertEqual(Set(body.sections.map(\.id)), expected, "ConsentBody.default must cover every required SectionID.")
    }

    func testOpenAIIsTheOnlyOutboundDestinationCalledOut() {
        let section = body.section(for: .openAIOnly)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.english.localizedCaseInsensitiveContains("openai"))
        XCTAssertTrue(
            section!.english.localizedCaseInsensitiveContains("only")
            || section!.english.localizedCaseInsensitiveContains("sole"),
            "Section must state OpenAI is the only / sole outbound destination."
        )
    }

    func testCaptureSetEnumeratesTheV0Categories() {
        // CONTEXT.md Capture Set v0 is exactly: app_name, window_title,
        // selected_text, project_name, workspace_path, on-demand screenshot.
        let section = body.section(for: .captureSet)
        XCTAssertNotNil(section)
        let lower = section!.english.lowercased()
        XCTAssertTrue(lower.contains("app"))
        XCTAssertTrue(lower.contains("window"))
        XCTAssertTrue(lower.contains("selected text"))
        XCTAssertTrue(lower.contains("project") || lower.contains("workspace"))
        XCTAssertTrue(lower.contains("screenshot"))
    }

    func testVoiceTurnAudioIsExplainedAsInMemoryByDefault() {
        let section = body.section(for: .voiceTurnEphemeral)
        XCTAssertNotNil(section)
        let lower = section!.english.lowercased()
        XCTAssertTrue(lower.contains("voice turn"), "Domain term `Voice Turn` must appear verbatim per CONTEXT.md.")
        XCTAssertTrue(lower.contains("memory") || lower.contains("not stored") || lower.contains("discarded"))
    }

    func testZDRRequestHeaderIsCalledOut() {
        let section = body.section(for: .zdrHeader)
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.english.localizedCaseInsensitiveContains("zero data retention")
                      || section!.english.localizedCaseInsensitiveContains("zdr"))
    }

    func testNoTelemetryClaimIsExplicit() {
        let section = body.section(for: .noTelemetry)
        XCTAssertNotNil(section)
        let lower = section!.english.lowercased()
        XCTAssertTrue(lower.contains("no telemetry") || lower.contains("no analytics") || lower.contains("no crash"))
    }

    func testPasteboardIsNeverReadIsExplicit() {
        let section = body.section(for: .noPasteboard)
        XCTAssertNotNil(section)
        let lower = section!.english.lowercased()
        XCTAssertTrue(lower.contains("pasteboard") || lower.contains("clipboard"))
        XCTAssertTrue(lower.contains("never") || lower.contains("not"))
    }

    func testOptInLoggingIsDocumented() {
        let section = body.section(for: .optInLogging)
        XCTAssertNotNil(section)
        let lower = section!.english.lowercased()
        XCTAssertTrue(lower.contains("opt-in") || lower.contains("opt in"))
        XCTAssertTrue(lower.contains("log") || lower.contains("session"))
    }

    func testCaptureSetSectionHasMandarinSubLine() {
        // The bilingual scope (CONTEXT.md) gives the Capture Set an
        // explicit Mandarin gloss; verify the most user-facing of the
        // sections has its zh-Hans line populated.
        let section = body.section(for: .captureSet)
        XCTAssertNotNil(section?.mandarin, "Capture Set section must include a zh-Hans sub-line.")
        XCTAssertFalse(section?.mandarin?.isEmpty ?? true)
    }
}
