// RealtimeWSClient — typed WebSocket client for the OpenAI Realtime GA
// API (`/v1/realtime`). Owns the upgrade request (Bearer auth only — the
// GA surface takes no `OpenAI-Beta` header; see `makeRequest`), runs the
// inbound receive loop, and forwards typed `RealtimeServerEvent`s through
// `inbound`.
//
// Reconnect: a single transport-level failure during `receive()` is
// recovered by reconnecting once and resuming the loop. A second
// failure surfaces as a fatal `error` event and the loop exits.

import Foundation

public enum RealtimeWSError: Error, Equatable, Sendable {
    case missingAPIKey
    case transportFailed(String)
    case alreadyConnected
}

public protocol RealtimeWSClient: AnyObject, Sendable {
    func connect() async throws
    func disconnect() async
    func send<E: Encodable>(_ event: E) async throws
    var inbound: AsyncStream<RealtimeServerEvent> { get }
}

public final class OpenAIRealtimeWSClient: RealtimeWSClient, @unchecked Sendable {

    public static let defaultEndpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    public static let defaultModel = "gpt-realtime-2"

    public let inbound: AsyncStream<RealtimeServerEvent>

    private let endpoint: URL
    private let model: String
    private let apiKey: String
    private let transport: RealtimeTransport
    private let continuation: AsyncStream<RealtimeServerEvent>.Continuation
    private var receiveTask: Task<Void, Never>?
    private var connected: Bool = false
    private let lock = NSLock()
    private let maxReconnectAttempts: Int

    public init(
        apiKey: String,
        model: String = OpenAIRealtimeWSClient.defaultModel,
        endpoint: URL = OpenAIRealtimeWSClient.defaultEndpoint,
        transport: RealtimeTransport = URLSessionTransport(),
        maxReconnectAttempts: Int = 1
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.transport = transport
        self.maxReconnectAttempts = maxReconnectAttempts
        var resolved: AsyncStream<RealtimeServerEvent>.Continuation!
        self.inbound = AsyncStream<RealtimeServerEvent> { cont in resolved = cont }
        self.continuation = resolved
    }

    public func connect() async throws {
        let alreadyConnected: Bool = lock.withLock { connected }
        guard !alreadyConnected else { throw RealtimeWSError.alreadyConnected }

        try await transport.connect(request: makeRequest())
        lock.withLock { connected = true }
        startReceiveLoop()
    }

    public func disconnect() async {
        lock.withLock { connected = false }
        receiveTask?.cancel()
        receiveTask = nil
        await transport.disconnect()
    }

    public func send<E: Encodable>(_ event: E) async throws {
        let data = try JSONEncoder().encode(event)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RealtimeWSError.transportFailed("could not utf8-encode outbound event")
        }
        try await transport.sendText(text)
    }

    /// Build the upgrade request with all required headers including
    /// the ZDR flag per ADR-0004. Made internal so tests can inspect it.
    func makeRequest() -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url ?? endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GA Realtime API (`/v1/realtime`) takes ONLY the Bearer header.
        // The `OpenAI-Beta: realtime=v1` header that the beta API required
        // now routes the request to the removed beta surface and the server
        // closes the socket with "The Realtime Beta API is no longer
        // supported." So it is deliberately absent.
        //
        // ZDR: the beta `OpenAI-Realtime-Zero-Data-Retention` request header
        // is not part of the GA surface. Zero-Data-Retention is configured
        // at the org/project level for GA, so per-connection header opt-in
        // (ADR-0004) is a follow-up once the GA mechanism is wired; sending
        // the dead beta header bought nothing and is dropped.
        return request
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    private func runReceiveLoop() async {
        var attemptsLeft = maxReconnectAttempts
        while !Task.isCancelled {
            do {
                let frame = try await transport.receive()
                handleFrame(frame)
            } catch {
                let isCancelled = Task.isCancelled
                if isCancelled { break }
                if attemptsLeft > 0 {
                    attemptsLeft -= 1
                    do {
                        await transport.disconnect()
                        try await transport.connect(request: makeRequest())
                        continue
                    } catch {
                        let message = (error as? RealtimeTransportError).map(String.init(describing:)) ?? error.localizedDescription
                        emitFatalError(.init(type: "error", error: .init(type: "transport_error", code: "reconnect_failed", message: message)))
                        break
                    }
                } else {
                    let message = (error as? RealtimeTransportError).map(String.init(describing:)) ?? error.localizedDescription
                    emitFatalError(.init(type: "error", error: .init(type: "transport_error", code: "stream_closed", message: message)))
                    break
                }
            }
        }
        continuation.finish()
    }

    private func handleFrame(_ frame: RealtimeTransportFrame) {
        let data: Data
        switch frame {
        case .text(let s):
            guard let bytes = s.data(using: .utf8) else { return }
            data = bytes
        case .data(let d):
            data = d
        }
        do {
            let event = try RealtimeEventDecoder.decode(from: data)
            continuation.yield(event)
        } catch {
            // Malformed inbound — surface as `unknown` rather than killing
            // the loop. Real-world this is rare; logging would mask a
            // server-side schema bump that we want to surface.
            continuation.yield(.unknown("malformed:\(error.localizedDescription)"))
        }
    }

    private func emitFatalError(_ event: RealtimeErrorEvent) {
        continuation.yield(.error(event))
    }
}
