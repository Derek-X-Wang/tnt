// RealtimeEvents — Codable models for the v0 OpenAI Realtime event
// shapes the Voice Provider talks. The taxonomy is a strict subset of
// OpenAI's published schema; anything we don't model decodes to
// `.unknown` so a server-side schema bump never crashes the client.
//
// Outbound events publish their `type` field via stored properties so
// `JSONEncoder` produces the canonical string verbatim.

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

// MARK: - Top-level dispatcher

public enum RealtimeServerEvent: Sendable, Equatable {
    case sessionCreated(SessionCreated)
    case responseAudioDelta(ResponseAudioDelta)
    case responseDone(ResponseDone)
    case error(RealtimeErrorEvent)
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
        default:
            return .unknown(envelope.type)
        }
    }
}
