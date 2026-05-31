// RealtimeEvents — Codable models for the v0 OpenAI Realtime event
// shapes the Voice Provider talks. The taxonomy is a strict subset of
// OpenAI's published schema; anything we don't model decodes to
// `.unknown` so a server-side schema bump never crashes the client.
//
// Outbound events publish their `type` field via stored properties so
// `JSONEncoder` produces the canonical string verbatim.
//
// Function-call support (issue #30): the GA Realtime API delivers tool
// calls via `response.function_call_arguments.done` and expects the
// result via `conversation.item.create` with `type: "function_call_output"`,
// followed by `response.create` to let the model continue speaking.

import Foundation

// MARK: - Outbound

public struct InputAudioBufferAppend: Codable, Sendable, Equatable {
    public var type: String
    public var audio: String

    public init(audio: String) {
        self.type = "input_audio_buffer.append"
        self.audio = audio
    }
}

public struct InputAudioBufferClear: Codable, Sendable, Equatable {
    public var type: String

    public init() {
        self.type = "input_audio_buffer.clear"
    }
}

public struct InputAudioBufferCommit: Codable, Sendable, Equatable {
    public var type: String

    public init() {
        self.type = "input_audio_buffer.commit"
    }
}

public struct ResponseCancel: Codable, Sendable, Equatable {
    public var type: String

    public init() {
        self.type = "response.cancel"
    }
}

public struct ResponseCreate: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public var instructions: String?
        public init(instructions: String? = nil) {
            self.instructions = instructions
        }
    }
    public var type: String
    public var response: Body

    public init(response: Body = Body()) {
        self.type = "response.create"
        self.response = response
    }
}

/// Outbound: return a function tool's result back to the Realtime model
/// so it can continue the conversation.
///
/// GA wire format:
/// ```json
/// {
///   "type": "conversation.item.create",
///   "item": {
///     "type": "function_call_output",
///     "call_id": "<the call_id from the server's function_call_arguments.done>",
///     "output": "<result string the model reads>"
///   }
/// }
/// ```
///
/// Per ADR-0006: the Appshot vision route re-injects the Cognitive Engine's
/// answer as a `function_call_output` so the Realtime model speaks it in
/// the same voice. Per ADR-0007: executor tool results also flow through
/// this path.
public struct ConversationItemCreateFunctionOutput: Codable, Sendable, Equatable {

    public struct Item: Codable, Sendable, Equatable {
        public let type: String
        public let callId: String
        public let output: String

        private enum CodingKeys: String, CodingKey {
            case type
            case callId = "call_id"
            case output
        }

        public init(callId: String, output: String) {
            self.type = "function_call_output"
            self.callId = callId
            self.output = output
        }
    }

    public let type: String
    public let item: Item

    private enum CodingKeys: String, CodingKey {
        case type
        case item
    }

    /// Convenience initialiser — sets `type` to `"conversation.item.create"`
    /// automatically.
    public init(callId: String, output: String) {
        self.type = "conversation.item.create"
        self.item = Item(callId: callId, output: output)
    }
}

// MARK: - Inbound

public struct ResponseAudioDelta: Codable, Sendable, Equatable {
    public let type: String
    /// Optional — present on the GA event but not load-bearing for the
    /// v0 player, so decoding never fails if the server reshapes them.
    public let responseId: String?
    public let itemId: String?
    /// base64-encoded PCM16 chunk.
    public let delta: String

    private enum CodingKeys: String, CodingKey {
        case type
        case responseId = "response_id"
        case itemId = "item_id"
        case delta
    }
}

public struct ResponseDone: Codable, Sendable, Equatable {
    public let type: String
}

public struct SessionCreated: Codable, Sendable, Equatable {
    public let type: String
}

public struct RealtimeErrorEvent: Codable, Sendable, Equatable {
    public struct Body: Codable, Sendable, Equatable {
        public let type: String?
        public let code: String?
        public let message: String?
    }
    public let type: String
    public let error: Body
}

/// Inbound: the GA server event carrying the model's function-call
/// arguments for a registered tool. The `arguments` field is a JSON
/// string (the model produces it, we forward it as-is to the handler).
///
/// GA wire shape (from `response.function_call_arguments.done`):
/// ```json
/// {
///   "type": "response.function_call_arguments.done",
///   "call_id": "call_abc123",
///   "name": "compose_agent_prompt",
///   "arguments": "{\"target\":\"claude-code\",\"intent\":\"add unit test\"}"
/// }
/// ```
/// Note: `call_id` and `name` may also arrive on the earlier
/// `response.output_item.done` frame — we decode from the `.done` frame
/// because it is the one that carries `arguments` and marks the call
/// as complete, matching the trigger point for dispatching to a handler.
public struct FunctionCallArgumentsDone: Codable, Sendable, Equatable {
    public let type: String
    public let callId: String
    public let name: String
    /// Raw JSON string of the model's arguments. The caller (M1 tool
    /// wiring) decodes this into the expected parameter type.
    public let argumentsJSON: String

    private enum CodingKeys: String, CodingKey {
        case type
        case callId = "call_id"
        case name
        case argumentsJSON = "arguments"
    }
}

// MARK: - Top-level dispatcher

public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated(SessionCreated)
    case responseAudioDelta(ResponseAudioDelta)
    case responseDone(ResponseDone)
    case error(RealtimeErrorEvent)
    /// The model has finished producing a tool call's arguments.
    /// The caller should decode `argumentsJSON`, call the tool, and
    /// return the result via `ConversationItemCreateFunctionOutput`
    /// followed by `ResponseCreate` to let the model continue.
    case functionCallArgumentsDone(callId: String, name: String, argumentsJSON: String)
    case unknown(String)
}

public enum RealtimeEventDecoder {

    private struct Envelope: Decodable {
        let type: String
    }

    /// Decode raw JSON into the typed `RealtimeServerEvent`. An
    /// unrecognised `type` returns `.unknown(typeString)` so the
    /// caller can choose whether to log + continue.
    public static func decode(from data: Data) throws -> RealtimeServerEvent {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope.type {
        case "session.created", "session.updated":
            return .sessionCreated(try JSONDecoder().decode(SessionCreated.self, from: data))
        // GA renamed `response.audio.delta` → `response.output_audio.delta`;
        // accept both so a server-side rename doesn't silence playback.
        case "response.audio.delta", "response.output_audio.delta":
            return .responseAudioDelta(try JSONDecoder().decode(ResponseAudioDelta.self, from: data))
        case "response.done":
            return .responseDone(try JSONDecoder().decode(ResponseDone.self, from: data))
        case "error":
            return .error(try JSONDecoder().decode(RealtimeErrorEvent.self, from: data))
        case "response.function_call_arguments.done":
            let payload = try JSONDecoder().decode(FunctionCallArgumentsDone.self, from: data)
            return .functionCallArgumentsDone(
                callId: payload.callId,
                name: payload.name,
                argumentsJSON: payload.argumentsJSON
            )
        default:
            return .unknown(envelope.type)
        }
    }
}
