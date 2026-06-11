// VisionPromptBuilder — assembles the multimodal chat/completions request
// for the M4b Tier-2 `analyze_screen` vision path (issue #123).
//
// Parallel to RewritePromptBuilder but NOT a modification of it.
// ChatMessage stays String-content so compose request fixtures remain
// byte-identical — this was the locked design from the M4 planning counsel
// rounds (issue #123 spec).
//
// Instead, vision uses VisionCompletionsRequest with content-parts arrays:
// - {type:"text"} parts carry the question, Window Text, and frozen context
//   labels (appName/windowTitle/project — same context info as ScreenTextSnapshot).
// - {type:"image_url", image_url:{url:"data:image/jpeg;base64,..."}} parts
//   carry JPEG image bytes.
//
// Degraded inputs:
// - Appshot with nil image → image part skipped, text note injected.
// - Appshot with nil image AND nil text → skipped entirely with note.
// - Oversized image (>imageByteLimit) → treated as nil; text note injected.
//
// No image resizing or processing happens here — the cap is a byte-size guard
// only. All resizing/quality decisions are at capture time (AppshotCapturer).
//
// Pure: imports Foundation + TNTCore only; no AppKit, no networking.

import Foundation
import TNTCore

// MARK: - Content parts

/// A single content part in a multimodal chat message.
/// Matches the OpenAI API wire format for vision requests.
public enum VisionContentPart: Encodable, Equatable, Sendable {

    case text(String)
    case imageURL(base64JPEG: String)

    // MARK: Encodable

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    private struct ImageURL: Encodable, Equatable {
        let url: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let content):
            try container.encode("text", forKey: .type)
            try container.encode(content, forKey: .text)
        case .imageURL(let base64):
            try container.encode("image_url", forKey: .type)
            let url = "data:image/jpeg;base64,\(base64)"
            try container.encode(ImageURL(url: url), forKey: .imageURL)
        }
    }
}

// MARK: - Vision chat message

/// A multimodal chat message with content-parts array.
/// Used only for the vision route — ChatMessage stays String-content
/// so compose fixtures remain byte-identical.
public struct VisionChatMessage: Encodable, Equatable, Sendable {
    public let role: String
    public let content: [VisionContentPart]

    public init(role: String, content: [VisionContentPart]) {
        self.role = role
        self.content = content
    }
}

// MARK: - Vision completions request

/// Multimodal request body for the OpenAI chat/completions vision path.
/// Parallel to the compose path; never mixed with ChatMessage-based requests.
public struct VisionCompletionsRequest: Encodable, Equatable, Sendable {
    public let model: String
    public let messages: [VisionChatMessage]

    public init(model: String, messages: [VisionChatMessage]) {
        self.model = model
        self.messages = messages
    }
}

// MARK: - VisionPromptBuilder

/// Builds a `VisionCompletionsRequest` from a list of Appshots and a question.
///
/// One appshot → one block of text + (optional) image parts:
///   - Text part: label header + Window Text (or "[no text available]")
///   - Image part: base64-encoded JPEG (skipped if nil or oversized)
///
/// Images larger than `imageByteLimit` are treated as missing — a text note
/// is injected so the model knows the image was skipped.
///
/// An appshot where BOTH imageJPEG and windowText are nil is skipped
/// entirely; a "[source N: no content available]" note replaces it.
public enum VisionPromptBuilder {

    // MARK: - Constants

    /// Maximum JPEG byte size accepted per image part (~20 MB).
    /// Oversized images are logged as unavailable; no resizing is done here.
    public static let imageByteLimit: Int = 20 * 1_024 * 1_024

    // MARK: - System prompt

    /// Vision system prompt: answer from image + Window Text, name the source window.
    /// Consistent with the ScreenTextSnapshot instruction (name-your-source) so the
    /// model maintains the same citing behaviour across both screen tiers.
    public static let systemPrompt: String = """
    You are the screen-vision assistant for TNT, a voice-first Personal Master Agent. \
    Your job: answer the user's question about what is on their screen using the \
    image(s) and window text provided.

    Rules:
    1. Always name the window you are reading from (e.g. "From your Cursor window: …").
    2. If multiple windows are provided, answer from the most relevant one and say which.
    3. Be concise. If the answer is visible in the image or text, give it directly.
    4. If the image was unavailable, say so and answer from the window text alone.
    5. If neither image nor text can answer the question, say you cannot see the answer \
       and suggest the user check Screen Recording permissions.
    """

    // MARK: - Public API

    /// Build a `VisionCompletionsRequest` from a question and Appshots.
    ///
    /// - Parameters:
    ///   - question: The user's question from the `analyze_screen` tool call.
    ///   - appshots: Resolved Appshots at dispatch time (armed + fresh grab).
    ///   - model: The vision model to use (default: `cognitiveModel`).
    /// - Returns: A `VisionCompletionsRequest` ready for the transport layer.
    public static func buildRequest(
        question: String,
        appshots: [Appshot],
        model: String
    ) -> VisionCompletionsRequest {
        let systemMsg = VisionChatMessage(role: "system", content: [.text(systemPrompt)])
        let userMsg = VisionChatMessage(
            role: "user",
            content: buildUserContent(question: question, appshots: appshots)
        )
        return VisionCompletionsRequest(model: model, messages: [systemMsg, userMsg])
    }

    // MARK: - Private helpers

    static func buildUserContent(question: String, appshots: [Appshot]) -> [VisionContentPart] {
        var parts: [VisionContentPart] = []

        // Leading question text.
        parts.append(.text("Question: \(question)"))

        if appshots.isEmpty {
            parts.append(.text("[No screen sources were provided.]"))
            return parts
        }

        // One block per appshot.
        for (idx, appshot) in appshots.enumerated() {
            let label = sourceLabel(appshot: appshot, index: idx)

            // Both nil → skip entirely with note.
            guard !appshot.isEmpty else {
                parts.append(.text("[\(label): no content available — skipped]"))
                continue
            }

            // Separator + label header.
            parts.append(.text("---\n\(label)"))

            // Window text part.
            if let text = appshot.windowText, !text.isEmpty {
                parts.append(.text("Window Text:\n\(text)"))
            } else {
                parts.append(.text("[no window text available for \(label)]"))
            }

            // Image part (skipped when nil or oversized).
            if let imageData = appshot.imageJPEG {
                if imageData.count > imageByteLimit {
                    let kb = imageData.count / 1_024
                    parts.append(.text("[image unavailable for \(label) — \(kb) KB exceeds limit]"))
                } else {
                    let base64 = imageData.base64EncodedString()
                    parts.append(.imageURL(base64JPEG: base64))
                }
            } else {
                parts.append(.text("[image unavailable for \(label)]"))
            }
        }

        return parts
    }

    /// Human-readable label for one Appshot source entry, using the frozen
    /// context fields (appName/windowTitle/project) so the model can name
    /// the source window in its answer.
    private static func sourceLabel(appshot: Appshot, index: Int) -> String {
        let app = appshot.appName ?? "Unknown"
        let title = appshot.windowTitle ?? ""
        if title.isEmpty {
            return "Source \(index + 1) (\(app))"
        }
        return "Source \(index + 1) — \(app): \(title)"
    }
}
