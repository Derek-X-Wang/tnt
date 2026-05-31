// TNTConfig — `~/.tnt/config` JSON reader for **non-secret** overrides.
// The OpenAI BYOK key lives in `TNTCredentials` (Keychain) and must
// never appear here. The reader fails loud (`secretInPlaintextConfig`)
// when a top-level field looks like an API key so a mis-pasted key
// can't silently land in plaintext.

import Foundation

public enum TNTConfigError: Error, Equatable, Sendable {
    case secretInPlaintextConfig(field: String)
    case malformed(reason: String)
}

public struct TNTConfig: Sendable, Equatable, Codable {

    public var realtimeModel: String?
    public var languageHints: [String]?
    /// Realtime voice id. Defaults to `alloy` when omitted; M0/S9
    /// makes this the only Realtime knob the User can override
    /// without rebuilding.
    public var voice: String?

    /// The non-Realtime model used by the **Cognitive Engine** for
    /// Rewrites, summarization, and (M4) vision-route Appshot answers.
    /// Per CONTEXT.md: "the Realtime model is NOT a Cognitive Engine"
    /// — this is a separate model field for a separate concern.
    /// Defaults to `"gpt-5.2"` when omitted.
    public var cognitiveModel: String

    /// Default cognitive model. Matches the `LocalOpenAIEngine` default
    /// and the M4 vision-route spec in ADR-0006.
    public static let defaultCognitiveModel = "gpt-5.2"

    public init(
        realtimeModel: String? = nil,
        languageHints: [String]? = nil,
        voice: String? = nil,
        cognitiveModel: String = TNTConfig.defaultCognitiveModel
    ) {
        self.realtimeModel = realtimeModel
        self.languageHints = languageHints
        self.voice = voice
        self.cognitiveModel = cognitiveModel
    }

    private enum CodingKeys: String, CodingKey {
        case realtimeModel = "realtime_model"
        case languageHints = "language_hints"
        case voice
        case cognitiveModel = "cognitive_model"
    }

    // MARK: - Custom Codable for cognitiveModel default

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.realtimeModel = try container.decodeIfPresent(String.self, forKey: .realtimeModel)
        self.languageHints = try container.decodeIfPresent([String].self, forKey: .languageHints)
        self.voice = try container.decodeIfPresent(String.self, forKey: .voice)
        self.cognitiveModel = try container.decodeIfPresent(String.self, forKey: .cognitiveModel)
            ?? TNTConfig.defaultCognitiveModel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(realtimeModel, forKey: .realtimeModel)
        try container.encodeIfPresent(languageHints, forKey: .languageHints)
        try container.encodeIfPresent(voice, forKey: .voice)
        try container.encode(cognitiveModel, forKey: .cognitiveModel)
    }

    /// Normalize a config field name for secret-guard comparison:
    /// lowercase + strip `_` and `-` separators so that `OPENAI_API_KEY`,
    /// `apiKey`, `api-key`, and `OpenAI_Key` all collapse to a common form.
    static func normalizeFieldName(_ raw: String) -> String {
        raw.lowercased()
           .filter { $0 != "_" && $0 != "-" }
    }

    /// Returns true when a normalized field name looks like an API key /
    /// secret that must never appear in the plaintext config.
    ///
    /// Broadened in issue #69 to catch common camelCase and env-var variants:
    ///   `OPENAI_API_KEY`, `apiKey`, `openaiKey`, `api-key`, `token`, `secret`.
    ///
    /// Rules (applied to the normalized form):
    ///   - Bare sensitive words: `key`, `token`, `secret`
    ///   - Any name containing both `api` and `key`
    ///   - Any name starting with `openai` and containing `key`, `token`, or `secret`
    static func looksLikeSecret(_ normalized: String) -> Bool {
        // Bare sensitive words.
        if normalized == "key" || normalized == "token" || normalized == "secret" {
            return true
        }
        // Contains both "api" and "key" (covers apikey, apiaccesskey, etc.)
        if normalized.contains("api") && normalized.contains("key") {
            return true
        }
        // OpenAI-prefixed variants (openaikey, openaitoken, openaisecret, etc.)
        if normalized.hasPrefix("openai") &&
           (normalized.contains("key") || normalized.contains("token") || normalized.contains("secret")) {
            return true
        }
        return false
    }

    /// Parse JSON bytes. The reader walks the top-level keys for the
    /// forbidden set *before* decoding so the error names the offending
    /// field even when the rest of the config is malformed.
    public static func parse(_ data: Data) throws -> TNTConfig {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw TNTConfigError.malformed(reason: error.localizedDescription)
        }
        guard let dict = object as? [String: Any] else {
            throw TNTConfigError.malformed(reason: "top-level must be a JSON object")
        }
        for rawKey in dict.keys {
            let normalized = normalizeFieldName(rawKey)
            if looksLikeSecret(normalized) {
                throw TNTConfigError.secretInPlaintextConfig(field: rawKey)
            }
        }
        do {
            return try JSONDecoder().decode(TNTConfig.self, from: data)
        } catch {
            throw TNTConfigError.malformed(reason: error.localizedDescription)
        }
    }

    /// Convenience for the runtime path that reads `~/.tnt/config`.
    public static func load(from url: URL) throws -> TNTConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TNTConfigError.malformed(reason: error.localizedDescription)
        }
        return try parse(data)
    }
}
