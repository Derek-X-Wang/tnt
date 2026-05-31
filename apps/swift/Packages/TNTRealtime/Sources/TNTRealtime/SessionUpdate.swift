// SessionUpdate — the configuration event sent on every WS connect so the
// Realtime session uses the v0 bilingual prompt + voice + PCM16 audio
// formats. Per M0/S9 acceptance, the client emits this on every
// `connect()`.
//
// GA schema (`/v1/realtime`, not the removed beta surface):
//
//   {
//     "type": "session.update",
//     "session": {
//       "type": "realtime",
//       "output_modalities": ["audio"],
//       "instructions": "...",
//       "audio": {
//         "input":  { "format": {"type":"audio/pcm","rate":24000},
//                     "turn_detection": null },
//         "output": { "format": {"type":"audio/pcm","rate":24000},
//                     "voice": "marin" }
//       },
//       "tools": [...],        // optional — M1+ only
//       "tool_choice": "auto"  // optional — "auto" | "none" | "required"
//     }
//   }
//
// Differences from the old beta shape this replaces: `modalities` →
// `output_modalities`; `voice` moved under `audio.output`; the flat
// `input_audio_format`/`output_audio_format` strings became
// `audio.{input,output}.format` objects; `type: "realtime"` is required;
// the non-standard `language` hint is gone (bilingual is handled entirely
// by the instructions). `turn_detection` is null because v0 is
// push-to-talk: the client drives commit + response.create on hotkey
// release, so server-side VAD must not also auto-respond.

import Foundation

// MARK: - RealtimeTool

/// A function tool registered on the Realtime session so the model can
/// call it mid-conversation. The `parameters` field is an arbitrary
/// JSON Schema object (e.g. `{"type":"object","properties":{...}}`).
///
/// GA wire key: `"type": "function"`. The `parameters` field encodes
/// as-is — pass a `JSONValue.schema(...)` helper or an `.object([...])`
/// literal for the JSON Schema body.
///
/// Per ADR-0006 and ADR-0007: the single vision tool (Appshot) and the
/// executor tools (Voice Actions) both ride this path — the codec
/// is intentionally type-agnostic so any tool payload is supported.
public struct RealtimeTool: Codable, Sendable, Equatable {

    /// Always `"function"` for GA Realtime tool definitions.
    public let type: String

    /// Stable snake_case tool name sent to the model
    /// (e.g. `"compose_agent_prompt"`, `"appshot_vision"`).
    public let name: String

    /// Human-readable description the model uses to decide when to
    /// call the tool. Keep it short and behavioural.
    public let description: String

    /// JSON Schema describing the tool's arguments object. The model
    /// generates a JSON string conforming to this schema when it calls
    /// the tool. Use `JSONValue.schema(...)` for common shapes.
    public let parameters: JSONValue

    public init(
        name: String,
        description: String,
        parameters: JSONValue
    ) {
        self.type = "function"
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - SessionUpdate

public struct SessionUpdate: Codable, Sendable, Equatable {

    /// `{ "type": "audio/pcm", "rate": 24000 }`.
    public struct AudioFormat: Codable, Sendable, Equatable {
        public var type: String
        public var rate: Int
        public init(type: String = "audio/pcm", rate: Int = 24_000) {
            self.type = type
            self.rate = rate
        }
    }

    public struct AudioInput: Codable, Sendable, Equatable {
        public var format: AudioFormat
        private enum CodingKeys: String, CodingKey {
            case format
            case turnDetection = "turn_detection"
        }
        public init(format: AudioFormat = .init()) {
            self.format = format
        }
        // Decode only `format`; `turn_detection` is write-only (always null
        // on the wire) so there's nothing to read back. Hand-rolled because
        // the custom `encode(to:)` suppresses synthesis of `init(from:)`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.format = try c.decode(AudioFormat.self, forKey: .format)
        }
        // v0 is push-to-talk: emit `turn_detection: null` explicitly
        // (encodeNil, not an omitted key) so the server clears its default
        // server_vad and the client drives every turn boundary via manual
        // commit + response.create. There is deliberately no stored value —
        // turn detection is a fixed invariant of the v0 Voice Turn, not a
        // tuning knob (VAD/wake-word is post-v0).
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format)
            try c.encodeNil(forKey: .turnDetection)
        }
    }

    public struct AudioOutput: Codable, Sendable, Equatable {
        public var format: AudioFormat
        public var voice: String
        public init(format: AudioFormat = .init(), voice: String) {
            self.format = format
            self.voice = voice
        }
    }

    public struct Audio: Codable, Sendable, Equatable {
        public var input: AudioInput
        public var output: AudioOutput
        public init(input: AudioInput, output: AudioOutput) {
            self.input = input
            self.output = output
        }
    }

    public struct Body: Codable, Sendable, Equatable {
        public var type: String
        public var outputModalities: [String]
        public var instructions: String?
        public var audio: Audio

        /// Function tools available to the model during the session.
        /// Nil = no tools (the model is conversational only).
        /// Set to the vision tool + executor tools when M1/M4/M5 land.
        public var tools: [RealtimeTool]?

        /// How the model selects tools. `"auto"` (default) lets the
        /// model decide; `"none"` disables tool calling even if tools
        /// are registered; `"required"` forces a tool call.
        /// GA key: `"tool_choice"`.
        public var toolChoice: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case outputModalities = "output_modalities"
            case instructions
            case audio
            case tools
            case toolChoice = "tool_choice"
        }

        public init(
            type: String = "realtime",
            // GA allows EITHER ["audio"] OR ["text"], never both — the
            // server rejects ["audio","text"]. Audio responses already
            // carry a transcript, so ["audio"] is the right ask for a
            // spoken reply. (Verified against the Realtime GA reference.)
            outputModalities: [String] = ["audio"],
            instructions: String? = nil,
            audio: Audio,
            tools: [RealtimeTool]? = nil,
            toolChoice: String? = nil
        ) {
            self.type = type
            self.outputModalities = outputModalities
            self.instructions = instructions
            self.audio = audio
            self.tools = tools
            self.toolChoice = toolChoice
        }

        /// Return a copy of this Body with `newTools` appended to `tools`
        /// and `tool_choice` set. The single primitive the per-feature
        /// `with…Tools()` helpers (Rewrite, vision, future M5 executor
        /// tools) delegate to, so the append + tool_choice logic lives in
        /// exactly one place.
        public func appendingTools(
            _ newTools: [RealtimeTool],
            toolChoice: String = "auto"
        ) -> Body {
            var copy = self
            copy.tools = (copy.tools ?? []) + newTools
            copy.toolChoice = toolChoice
            return copy
        }
    }

    public var type: String
    public var session: Body

    public init(session: Body) {
        self.type = "session.update"
        self.session = session
    }

    /// v0 bilingual default. `voice` overridable via `~/.tnt/config`.
    public static func bilingualV0(voice: String = "marin") -> SessionUpdate {
        SessionUpdate(session: Body(
            outputModalities: ["audio"],
            instructions: RealtimePrompts.v0System,
            audio: Audio(
                input: AudioInput(),
                output: AudioOutput(voice: voice)
            )
        ))
    }
}
