import XCTest
@testable import TNTCore

/// Tests for `Appshot` + `CaptureSet.appshots` (issue #33).
///
/// Acceptance criteria:
/// - `Appshot` exists as Codable/Sendable with the required fields.
/// - `isEmpty` true only when both imageJPEG and windowText are nil.
/// - `CaptureSet.appshots` defaults to []; a set with appshots is not isEmpty.
/// - Codable round-trips for Appshot (with and without image) and for a
///   CaptureSet carrying ≥2 stacked Appshots.
/// - Frozen context fields round-trip independently of live CaptureSet fields.
final class AppshotTests: XCTestCase {

    // MARK: - Appshot isEmpty

    func testAppshotIsEmptyWhenBothNil() {
        let appshot = Appshot()
        XCTAssertTrue(appshot.isEmpty)
    }

    func testAppshotWithImageIsNotEmpty() {
        let appshot = Appshot(imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertFalse(appshot.isEmpty)
    }

    func testAppshotWithWindowTextIsNotEmpty() {
        let appshot = Appshot(windowText: "func rateLimitMiddleware()")
        XCTAssertFalse(appshot.isEmpty)
    }

    func testAppshotWithOnlyContextFieldsIsEmpty() {
        // Per the spec: isEmpty is true when BOTH imageJPEG AND windowText
        // are nil — metadata-only appshots bring no new signal.
        let appshot = Appshot(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            project: ProjectRef(name: "tnt")
        )
        XCTAssertTrue(appshot.isEmpty,
            "An Appshot with only context metadata (no image/text) must be isEmpty")
    }

    // MARK: - Appshot Codable round-trips

    func testAppshotRoundTripAllNils() throws {
        let original = Appshot()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Appshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testAppshotRoundTripWithImage() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0]) // minimal JPEG header
        let original = Appshot(
            imageJPEG: imageData,
            windowText: "Error: undefined reference to 'rate_limit'",
            appName: "Cursor",
            windowTitle: "main.c — tnt",
            project: ProjectRef(name: "tnt", path: "/Users/dev/tnt")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Appshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.imageJPEG, imageData)
        XCTAssertEqual(decoded.windowText, "Error: undefined reference to 'rate_limit'")
        XCTAssertEqual(decoded.appName, "Cursor")
        XCTAssertEqual(decoded.project?.name, "tnt")
    }

    func testAppshotRoundTripWithoutImage() throws {
        // WindowText only — common when Screen Recording TCC is not granted.
        let original = Appshot(
            windowText: "Dear team,\nHere's the status update…",
            appName: "Mail",
            windowTitle: "Status Update — Inbox"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Appshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.imageJPEG)
    }

    // MARK: - CaptureSet.appshots

    func testCaptureSetAppshotsDefaultsToEmpty() {
        let set = CaptureSet()
        XCTAssertTrue(set.appshots.isEmpty)
        XCTAssertTrue(set.isEmpty)
    }

    func testCaptureSetWithAppshotsIsNotEmpty() {
        let appshot = Appshot(imageJPEG: Data([0x01]))
        let set = CaptureSet(appshots: [appshot])
        XCTAssertFalse(set.isEmpty,
            "A CaptureSet with appshots must not be isEmpty")
    }

    func testCaptureSetWithTwoStackedAppshots() throws {
        // Per CONTEXT.md: "compare this design to that spec" — two Appshots
        // stack into one turn.
        let cursor = Appshot(
            imageJPEG: Data([0x01]),
            windowText: "fn rate_limit(ip: &str) -> bool {",
            appName: "Cursor",
            windowTitle: "rate_limit.rs — tnt",
            project: ProjectRef(name: "tnt")
        )
        let figma = Appshot(
            imageJPEG: Data([0x02]),
            windowText: nil,
            appName: "Figma",
            windowTitle: "Design spec — v2"
        )
        let set = CaptureSet(
            appName: "Cursor",
            appshots: [cursor, figma]
        )

        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)
        XCTAssertEqual(decoded.appshots.count, 2)
        XCTAssertEqual(decoded.appshots[0], cursor)
        XCTAssertEqual(decoded.appshots[1], figma)
    }

    // MARK: - Frozen context independence

    /// Per CONTEXT.md: an Appshot armed in Cursor stays labeled "Cursor"
    /// even if the user switches to Slack before speaking. The frozen
    /// appName inside the Appshot is independent of the live CaptureSet's
    /// appName.
    func testFrozenAppshotContextIsIndependentOfLiveCaptureSetContext() throws {
        // Appshot frozen as "Cursor" while the live CaptureSet's top-level
        // appName reflects "Slack" (the user switched after arming).
        let cursorAppshot = Appshot(
            imageJPEG: Data([0xAB]),
            windowText: "func compose()",
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            project: ProjectRef(name: "tnt")
        )
        let set = CaptureSet(
            appName: "Slack",    // live: user is now in Slack
            windowTitle: "#engineering",
            appshots: [cursorAppshot]
        )

        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)

        // Live context
        XCTAssertEqual(decoded.appName, "Slack",
            "CaptureSet.appName should reflect the live (current) context")
        // Frozen context inside the Appshot
        XCTAssertEqual(decoded.appshots.first?.appName, "Cursor",
            "Appshot.appName must stay 'Cursor' — frozen at arm time")
        XCTAssertEqual(decoded.appshots.first?.project?.name, "tnt")
    }

    func testCaptureSetEmptyWithAppshotFieldDefaultsToEmpty() throws {
        // CaptureSet.empty must still be empty with the appshots field present.
        XCTAssertTrue(CaptureSet.empty.isEmpty)
        XCTAssertTrue(CaptureSet.empty.appshots.isEmpty)
    }

    func testExistingCaptureSetSerializationStillWorks() throws {
        // Ensure the addition of appshots doesn't break existing Codable
        // CaptureSet payloads (backwards compatible default).
        let original = CaptureSet(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "func rate_limit()",
            project: ProjectRef(name: "tnt")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CaptureSet.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.appshots.isEmpty)
    }
}
