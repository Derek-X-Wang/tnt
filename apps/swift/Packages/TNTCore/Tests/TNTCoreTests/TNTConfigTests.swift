import XCTest
@testable import TNTCore

/// `~/.tnt/config` reader behaviour.
///
/// Per the M0/S5 acceptance criterion, the plaintext config is for non-
/// secret overrides only. The reader rejects any field that looks like
/// an API key with a clear error so a misconfigured install fails loud
/// rather than silently leaking the key to disk.
final class TNTConfigTests: XCTestCase {

    func testEmptyConfigParsesToEmptyValue() throws {
        let config = try TNTConfig.parse(Data("{}".utf8))
        XCTAssertNil(config.realtimeModel)
        XCTAssertNil(config.languageHints)
    }

    func testKnownFieldsRoundTrip() throws {
        let json = """
        {
          "realtime_model": "gpt-realtime-2",
          "language_hints": ["en", "zh"]
        }
        """
        let config = try TNTConfig.parse(Data(json.utf8))
        XCTAssertEqual(config.realtimeModel, "gpt-realtime-2")
        XCTAssertEqual(config.languageHints, ["en", "zh"])
    }

    func testRejectsTopLevelKeyField() {
        let json = #"{"key": "sk-leaked"}"#
        XCTAssertThrowsError(try TNTConfig.parse(Data(json.utf8))) { error in
            guard case TNTConfigError.secretInPlaintextConfig(let field) = error else {
                XCTFail("Expected secretInPlaintextConfig, got \(error)")
                return
            }
            XCTAssertEqual(field, "key")
        }
    }

    func testRejectsTopLevelApiKeyField() {
        let json = #"{"api_key": "sk-leaked"}"#
        XCTAssertThrowsError(try TNTConfig.parse(Data(json.utf8))) { error in
            guard case TNTConfigError.secretInPlaintextConfig(let field) = error else {
                XCTFail("Expected secretInPlaintextConfig, got \(error)")
                return
            }
            XCTAssertEqual(field, "api_key")
        }
    }

    func testRejectsTopLevelOpenAIKeyField() {
        let json = #"{"openai_key": "sk-leaked"}"#
        XCTAssertThrowsError(try TNTConfig.parse(Data(json.utf8))) { error in
            guard case TNTConfigError.secretInPlaintextConfig = error else {
                XCTFail("Expected secretInPlaintextConfig, got \(error)")
                return
            }
        }
    }

    func testRejectsCaseVariantKeyField() {
        let json = #"{"OpenAI_Key": "sk-leaked"}"#
        // Case variants must not slip past the check.
        XCTAssertThrowsError(try TNTConfig.parse(Data(json.utf8)))
    }

    func testMalformedJsonThrowsMalformed() {
        XCTAssertThrowsError(try TNTConfig.parse(Data("not json".utf8))) { error in
            guard case TNTConfigError.malformed = error else {
                XCTFail("Expected malformed, got \(error)")
                return
            }
        }
    }

    func testRejectsNonObjectTopLevel() {
        // A bare array or string at the top level is not a valid config.
        XCTAssertThrowsError(try TNTConfig.parse(Data("[1,2,3]".utf8)))
    }
}
