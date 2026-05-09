// SessionUpdate — the configuration event sent on every WS connect
// so the Realtime session uses the v0 bilingual prompt + voice +
// language hints. Per M0/S9 acceptance, the client must emit this on
// every `connect()`.
//
// Modelled as a top-level Codable struct rather than an envelope-
// generic so JSON encoding produces the canonical `type` /
// `session` shape verbatim.

import Foundation

public struct SessionUpdate: Codable, Sendable, Equatable {

    public struct Body: Codable, Sendable, Equatable {
        public var modalities: [String]?
        public var instructions: String?
        public var voice: String?
        /// Language hints. v0 is `["en", "zh"]` per the bilingual scope
        /// in CONTEXT.md. Sent even when the server may not honour the
        /// field directly so the wire is forward-compat with future
        /// Realtime API extensions.
        public var language: [String]?

        public init(
            modalities: [String]? = nil,
            instructions: String? = nil,
            voice: String? = nil,
            language: [String]? = nil
        ) {
            self.modalities = modalities
            self.instructions = instructions
            self.voice = voice
            self.language = language
        }
    }

    public var type: String
    public var session: Body

    public init(session: Body) {
        self.type = "session.update"
        self.session = session
    }

    /// v0 bilingual default. `voice` overridable via `~/.tnt/config`.
    public static func bilingualV0(voice: String = "alloy") -> SessionUpdate {
        SessionUpdate(session: Body(
            modalities: ["audio", "text"],
            instructions: RealtimePrompts.v0System,
            voice: voice,
            language: ["en", "zh"]
        ))
    }
}
