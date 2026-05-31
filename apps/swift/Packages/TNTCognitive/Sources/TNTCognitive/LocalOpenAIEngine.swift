// LocalOpenAIEngine — v0 implementation of CognitiveEngine that calls
// OpenAI's chat/completions endpoint directly from the Desktop App.
//
// Per ADR-0003: this is the v0 impl of the server-future CognitiveEngine
// protocol. The v1 impl (RemoteEngine) will call tnt-server instead —
// the composition root in TNTMac is the only site that changes.
//
// Per ADR-0004: every Cognitive Engine call sets the OpenAI
// Zero-Data-Retention header (`OpenAI-ZDR: true`) at the application
// layer. For non-Realtime (standard chat/completions) calls, this header
// is separate from the org/project-level ZDR setting and must be set
// explicitly per request (unlike the GA Realtime surface which dropped
// the per-request header — see the ADR-0004 amendment and the Realtime
// notes in memory).
//
// URLSession injection: the `transport` parameter accepts any
// `CognitiveTransport` (a small send+receive protocol) so tests can
// replay recorded OpenAI responses without live network. Production
// code passes `URLSessionTransport(session: .shared)`.

import Foundation
import TNTCore

// MARK: - Transport protocol

/// Minimal transport seam for injecting network behavior in tests.
/// Not behind `protocol` in the ADR-0003 sense — this is a test
/// seam, not a server-future boundary (the boundary is CognitiveEngine
/// itself, per ADR-0007 decision 2 reasoning).
public protocol CognitiveTransport: Sendable {
    func send(request: URLRequest) async throws -> (Data, URLResponse)
}

/// Production transport — wraps `URLSession`.
public struct URLSessionCognitiveTransport: CognitiveTransport, Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func send(request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - LocalOpenAIEngine

/// v0 implementation of `CognitiveEngine`. Calls OpenAI chat/completions
/// directly from the Desktop App using the user's BYOK key.
public final class LocalOpenAIEngine: CognitiveEngine, @unchecked Sendable {

    private let apiKey: String
    private let model: String
    private let transport: CognitiveTransport

    /// Base URL for the OpenAI chat completions endpoint.
    public static let completionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(
        apiKey: String,
        model: String = TNTConfig.defaultCognitiveModel,
        transport: CognitiveTransport = URLSessionCognitiveTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
    }

    // MARK: - CognitiveEngine

    public func compose(
        target: AgentRef,
        intent: String,
        raw: String,
        capture: CaptureSet
    ) async throws -> String {
        let messages = RewritePromptBuilder.buildMessages(
            target: target,
            intent: intent,
            raw: raw,
            capture: capture
        )
        return try await callCompletions(messages: messages)
    }

    // MARK: - Private

    private func callCompletions(messages: [ChatMessage]) async throws -> String {
        let request = try buildRequest(messages: messages)
        let (data, response) = try await transport.send(request: request)
        return try parseResponse(data: data, response: response)
    }

    func buildRequest(messages: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: Self.completionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Per ADR-0004: set ZDR header on every Cognitive Engine call.
        // For non-Realtime (chat/completions) calls this is a request-level
        // header. Distinct from the GA Realtime surface which dropped this
        // header (see ADR-0004 amendment and tnt-realtime-is-ga memory).
        request.setValue("true", forHTTPHeaderField: "OpenAI-ZDR")

        let body = CompletionsRequest(model: model, messages: messages)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func parseResponse(data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else {
            throw LocalOpenAIEngineError.unexpectedResponse("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LocalOpenAIEngineError.httpError(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(CompletionsResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LocalOpenAIEngineError.emptyResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Error

public enum LocalOpenAIEngineError: Error, Equatable, Sendable {
    case httpError(Int, String)
    case emptyResponse
    case unexpectedResponse(String)
}

// MARK: - Wire types

private struct CompletionsRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
}

private struct CompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}
