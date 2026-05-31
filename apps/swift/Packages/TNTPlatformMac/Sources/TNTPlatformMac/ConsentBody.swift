// ConsentBody — the plain-language privacy posture shown on first run.
//
// Every category required by the M0/S4 acceptance criterion (and by
// docs/adr/0004 — Privacy posture v0) gets its own `Section` with a
// stable `SectionID`. Tests assert the contract by ID so reviewers can
// edit copy without breaking the requirements check, and so a missing
// section fails loud rather than slipping through visual review.
//
// The bilingual scope (CONTEXT.md) makes Mandarin sub-lines first-class
// where they materially help comprehension; the rest stay English-only
// to keep the screen short.

import Foundation

public struct ConsentBody: Sendable, Equatable {

    /// Stable identifier for each privacy section. Adding a new case is
    /// a deliberate change to the v0 privacy contract — never a silent
    /// drift.
    public enum SectionID: String, Sendable, CaseIterable, Equatable {
        case openAIOnly
        case captureSet
        case voiceTurnEphemeral
        case zdrHeader
        case noTelemetry
        case noPasteboard
        case optInLogging
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public let id: SectionID
        public let title: String
        public let english: String
        public let mandarin: String?

        public init(id: SectionID, title: String, english: String, mandarin: String? = nil) {
            self.id = id
            self.title = title
            self.english = english
            self.mandarin = mandarin
        }
    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public func section(for id: SectionID) -> Section? {
        sections.first { $0.id == id }
    }

    /// Default consent body shown by `OnboardingView`. Copy is short on
    /// purpose — the screen must read in under a minute.
    public static let `default`: ConsentBody = ConsentBody(sections: [
        Section(
            id: .openAIOnly,
            title: "Outbound traffic",
            english: "TNT only sends data to OpenAI, using the API key you provide. No other servers are contacted.",
            mandarin: "TNT 只会通过你提供的 API key 把数据发送到 OpenAI。不会联系任何其他服务器。"
        ),
        Section(
            id: .captureSet,
            title: "What gets captured",
            english: "When you start a Voice Turn, TNT can attach context to the prompt: active app, frontmost window title, selected text, project name and workspace path, and on-demand screenshots when you say \"look at this.\"",
            mandarin: "在你开始 Voice Turn 时，TNT 可以附带：活跃 app、最前窗口标题、选中的文字、项目名和工作区路径，以及当你说 \"look at this\" 时按需抓取的屏幕截图。"
        ),
        Section(
            id: .voiceTurnEphemeral,
            title: "Voice Turn audio",
            english: "Voice Turn audio and transcripts live in memory only. They are not stored on disk by default.",
            mandarin: nil
        ),
        Section(
            id: .zdrHeader,
            title: "Zero Data Retention",
            english: "If your OpenAI organization has Zero Data Retention (ZDR) enabled, OpenAI does not retain your requests. ZDR is configured on your OpenAI account, not by TNT.",
            mandarin: nil
        ),
        Section(
            id: .noTelemetry,
            title: "No telemetry",
            english: "No telemetry, no analytics, no crash reports. The app contains no third-party tracking SDKs.",
            mandarin: nil
        ),
        Section(
            id: .noPasteboard,
            title: "Pasteboard",
            english: "TNT never reads your pasteboard. Copying a password will not leak it.",
            mandarin: nil
        ),
        Section(
            id: .optInLogging,
            title: "Opt-in session logging",
            english: "Session logging is opt-in. Voice Turn audio + transcripts only get written to disk when you explicitly enable session logs; off by default and documented separately.",
            mandarin: nil
        ),
    ])
}
