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

    // MARK: - Issue #69: broadened plaintext-secret guard

    /// Table-driven test of all variants that must be rejected.
    /// The guard normalizes each key (lowercase + strip _/-) before
    /// matching, so camelCase, SCREAMING_SNAKE, and kebab-case forms
    /// all trip the check.
    func testSecretGuardRejectsAllKnownVariants() {
        let rejectCases: [(json: String, label: String)] = [
            // Original variants (must remain rejected)
            (#"{"key": "sk-..."}"#,          "bare key"),
            (#"{"api_key": "sk-..."}"#,      "api_key"),
            (#"{"openai_key": "sk-..."}"#,   "openai_key"),
            (#"{"OpenAI_Key": "sk-..."}"#,   "OpenAI_Key (case variant)"),
            // New variants caught by broadened guard (issue #69)
            (#"{"OPENAI_API_KEY": "sk-..."}"#, "OPENAI_API_KEY (env-var form)"),
            (#"{"apiKey": "sk-..."}"#,        "apiKey (camelCase)"),
            (#"{"openaiKey": "sk-..."}"#,     "openaiKey (camelCase)"),
            (#"{"api-key": "sk-..."}"#,       "api-key (kebab-case)"),
            (#"{"token": "tok-..."}"#,         "bare token"),
            (#"{"secret": "sec-..."}"#,        "bare secret"),
        ]

        for (json, label) in rejectCases {
            XCTAssertThrowsError(
                try TNTConfig.parse(Data(json.utf8)),
                "Expected secretInPlaintextConfig for '\(label)'"
            ) { error in
                guard case TNTConfigError.secretInPlaintextConfig = error else {
                    XCTFail("'\(label)': expected secretInPlaintextConfig, got \(error)")
                    return
                }
            }
        }
    }

    /// Legitimate config keys must all be accepted without error.
    func testLegitimateConfigKeysAreAccepted() throws {
        let json = """
        {
          "realtime_model": "gpt-realtime-2",
          "language_hints": ["en", "zh"],
          "voice": "marin",
          "cognitive_model": "gpt-5.2"
        }
        """
        let config = try TNTConfig.parse(Data(json.utf8))
        XCTAssertEqual(config.realtimeModel, "gpt-realtime-2")
        XCTAssertEqual(config.languageHints, ["en", "zh"])
        XCTAssertEqual(config.voice, "marin")
        XCTAssertEqual(config.cognitiveModel, "gpt-5.2")
    }

    /// Verify the field name normalization helper directly.
    func testNormalizeFieldNameStripsUnderscoresAndDashes() {
        XCTAssertEqual(TNTConfig.normalizeFieldName("OPENAI_API_KEY"), "openaiapikey")
        XCTAssertEqual(TNTConfig.normalizeFieldName("apiKey"), "apikey")
        XCTAssertEqual(TNTConfig.normalizeFieldName("api-key"), "apikey")
        XCTAssertEqual(TNTConfig.normalizeFieldName("realtime_model"), "realtimemodel")
    }

    /// Verify the looksLikeSecret predicate directly with known inputs.
    func testLooksLikeSecretMatchesExpectedCases() {
        // Should match:
        XCTAssertTrue(TNTConfig.looksLikeSecret("key"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("token"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("secret"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("apikey"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("openaiapikey"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("openaikey"))
        XCTAssertTrue(TNTConfig.looksLikeSecret("openaisecret"))
        // Should not match:
        XCTAssertFalse(TNTConfig.looksLikeSecret("realtimemodel"))
        XCTAssertFalse(TNTConfig.looksLikeSecret("languagehints"))
        XCTAssertFalse(TNTConfig.looksLikeSecret("voice"))
        XCTAssertFalse(TNTConfig.looksLikeSecret("cognitivemodel"))
    }
}
