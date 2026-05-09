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

    public init(realtimeModel: String? = nil, languageHints: [String]? = nil) {
        self.realtimeModel = realtimeModel
        self.languageHints = languageHints
    }

    private enum CodingKeys: String, CodingKey {
        case realtimeModel = "realtime_model"
        case languageHints = "language_hints"
    }

    /// Top-level fields that must never appear in `~/.tnt/config`. Any
    /// case variant trips the check.
    public static let forbiddenKeyFields: Set<String> = ["key", "api_key", "openai_key"]

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
            if forbiddenKeyFields.contains(rawKey.lowercased()) {
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
