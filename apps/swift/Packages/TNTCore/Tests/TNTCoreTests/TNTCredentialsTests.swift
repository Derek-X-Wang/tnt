import XCTest
@testable import TNTCore

/// Round-trip tests for the `TNTCredentials` Keychain wrapper.
///
/// Each test uses a per-instance service prefix so they cannot pollute
/// the developer's real `com.tnt.app` Keychain entry, and `tearDown`
/// always cleans up via `deleteOpenAIKey(service:)` — per the M0/S5
/// acceptance criterion.
final class TNTCredentialsTests: XCTestCase {

    private var testService: String = ""

    override func setUp() {
        super.setUp()
        testService = "com.tnt.app.test.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Best-effort cleanup so test runs are idempotent.
        try? TNTCredentials.deleteOpenAIKey(service: testService)
        super.tearDown()
    }

    func testDefaultServiceMatchesAcceptanceCriterion() {
        XCTAssertEqual(TNTCredentials.defaultService, "com.tnt.app")
        XCTAssertEqual(TNTCredentials.account, "openai-api-key")
    }

    func testReadingMissingKeyThrowsItemNotFound() {
        XCTAssertThrowsError(try TNTCredentials.openAIKey(service: testService)) { error in
            guard case TNTCredentialsError.itemNotFound = error else {
                XCTFail("Expected itemNotFound, got \(error)")
                return
            }
        }
    }

    func testSetThenReadRoundTripsTheKey() throws {
        try TNTCredentials.setOpenAIKey("sk-test-1234567890", service: testService)
        XCTAssertEqual(try TNTCredentials.openAIKey(service: testService), "sk-test-1234567890")
    }

    func testSetTwiceOverwritesTheStoredKey() throws {
        try TNTCredentials.setOpenAIKey("sk-first", service: testService)
        try TNTCredentials.setOpenAIKey("sk-second", service: testService)
        XCTAssertEqual(try TNTCredentials.openAIKey(service: testService), "sk-second")
    }

    func testDeleteRemovesTheKey() throws {
        try TNTCredentials.setOpenAIKey("sk-removable", service: testService)
        try TNTCredentials.deleteOpenAIKey(service: testService)
        XCTAssertThrowsError(try TNTCredentials.openAIKey(service: testService))
    }

    func testDeleteIsIdempotentWhenItemMissing() {
        // Removing a non-existent key must not error — keeps the
        // Replace-API-Key flow free of "did the previous key exist?"
        // bookkeeping.
        XCTAssertNoThrow(try TNTCredentials.deleteOpenAIKey(service: testService))
    }

    func testEmptyKeyIsRejected() {
        XCTAssertThrowsError(try TNTCredentials.setOpenAIKey("", service: testService)) { error in
            guard case TNTCredentialsError.invalidKey = error else {
                XCTFail("Expected invalidKey, got \(error)")
                return
            }
        }
    }
}
