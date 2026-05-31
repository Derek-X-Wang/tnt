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

    // MARK: - cognitiveModel (issue #29)

    func testCognitiveModelDefaultsToGPT52() throws {
        // An empty config must produce the default cognitive model,
        // not nil — so LocalOpenAIEngine always has a model to call.
        let config = try TNTConfig.parse(Data("{}".utf8))
        XCTAssertEqual(config.cognitiveModel, TNTConfig.defaultCognitiveModel)
        XCTAssertEqual(config.cognitiveModel, "gpt-5.2")
    }

    func testCognitiveModelOverrideIsHonored() throws {
        let json = #"{"cognitive_model": "gpt-4o"}"#
        let config = try TNTConfig.parse(Data(json.utf8))
        XCTAssertEqual(config.cognitiveModel, "gpt-4o",
            "cognitive_model in config must override the default")
    }

    func testCognitiveModelRoundTripsWithOtherFields() throws {
        let json = """
        {
          "realtime_model": "gpt-realtime-2",
          "cognitive_model": "gpt-4-turbo"
        }
        """
        let config = try TNTConfig.parse(Data(json.utf8))
        XCTAssertEqual(config.realtimeModel, "gpt-realtime-2")
        XCTAssertEqual(config.cognitiveModel, "gpt-4-turbo")
    }

    func testCognitiveModelDefaultWhenAbsentFromConfigFile() throws {
        // Simulate a config that existed before cognitiveModel was added.
        // The field must default gracefully — no parse error.
        let json = #"{"voice": "marin"}"#
        let config = try TNTConfig.parse(Data(json.utf8))
        XCTAssertEqual(config.cognitiveModel, TNTConfig.defaultCognitiveModel)
        XCTAssertEqual(config.voice, "marin")
    }
}
