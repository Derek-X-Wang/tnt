// RealtimeTransport — pinned-down minimum surface of the WebSocket
// transport used by `OpenAIRealtimeWSClient`. Everything `URLSessionWebSocketTask`
// exposes that the client actually needs is restated here so a `MockTransport`
// can drive the reconnect-on-failure integration test without standing
// up a real socket.
//
// Production code uses `URLSessionTransport`; tests use `MockTransport`.

import Foundation

public enum RealtimeTransportError: Error, Equatable, Sendable {
    case notConnected
    case streamClosed
    case wrappedURLSession(String)
}

public enum RealtimeTransportFrame: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public protocol RealtimeTransport: AnyObject, Sendable {
    /// Build the upgrade request and bring the socket up.
    func connect(request: URLRequest) async throws

    /// Close the socket; subsequent `send` / `receive` throw.
    func disconnect() async

    func sendText(_ text: String) async throws
    func receive() async throws -> RealtimeTransportFrame
}

/// Production transport — wraps a `URLSessionWebSocketTask`.
public final class URLSessionTransport: RealtimeTransport, @unchecked Sendable {

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(request: URLRequest) async throws {
        let task = session.webSocketTask(with: request)
        task.resume()
        lock.withLock { self.task = task }
    }

    public func disconnect() async {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            let snapshot = self.task
            self.task = nil
            return snapshot
        }
        task?.cancel(with: .goingAway, reason: nil)
    }

    public func sendText(_ text: String) async throws {
        guard let task = lock.withLock({ self.task }) else {
            throw RealtimeTransportError.notConnected
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw RealtimeTransportError.wrappedURLSession(error.localizedDescription)
        }
    }

    public func receive() async throws -> RealtimeTransportFrame {
        guard let task = lock.withLock({ self.task }) else {
            throw RealtimeTransportError.notConnected
        }
        do {
            let msg = try await task.receive()
            switch msg {
            case .string(let s): return .text(s)
            case .data(let d):   return .data(d)
            @unknown default:    throw RealtimeTransportError.streamClosed
            }
        } catch {
            throw RealtimeTransportError.wrappedURLSession(error.localizedDescription)
        }
    }
}

/// Test transport — a deterministic queue of inbound frames + a record
/// of every send. Mirrors the surface tests need without dragging in
/// `URLSession`'s factory machinery.
public final class MockTransport: RealtimeTransport, @unchecked Sendable {

    public private(set) var connectCount: Int = 0
    public private(set) var disconnectCount: Int = 0
    public private(set) var lastRequest: URLRequest?
    public private(set) var sendLog: [String] = []

    /// Programmable inbound queue. `MockTransport.receive()` pulls
    /// from the front; if the queue empties, subsequent calls await a
    /// pumped result via `enqueue(_:)` or throw `streamClosed` if
    /// `closeAfterDrain` is set.
    public var closeAfterDrain: Bool = false

    private var inboundQueue: [Result<RealtimeTransportFrame, Error>] = []
    private var awaiters: [CheckedContinuation<Result<RealtimeTransportFrame, Error>, Never>] = []
    private var connected: Bool = false
    private let lock = NSLock()

    public init() {}

    public func connect(request: URLRequest) async throws {
        lock.withLock {
            connectCount += 1
            connected = true
            lastRequest = request
        }
    }

    public func disconnect() async {
        lock.withLock {
            disconnectCount += 1
            connected = false
        }
    }

    public func sendText(_ text: String) async throws {
        let isConnected: Bool = lock.withLock { connected }
        guard isConnected else { throw RealtimeTransportError.notConnected }
        lock.withLock { sendLog.append(text) }
    }

    public func receive() async throws -> RealtimeTransportFrame {
        let pulled: Result<RealtimeTransportFrame, Error>? = lock.withLock {
            guard connected else { return .failure(RealtimeTransportError.notConnected) }
            if !inboundQueue.isEmpty {
                return inboundQueue.removeFirst()
            }
            if closeAfterDrain {
                return .failure(RealtimeTransportError.streamClosed)
            }
            return nil
        }

        if let pulled = pulled {
            return try pulled.get()
        }

        // Park until enqueue pumps a frame.
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<RealtimeTransportFrame, Error>, Never>) in
            lock.withLock { awaiters.append(cont) }
        }
        return try result.get()
    }

    /// Push an inbound frame. Wakes any pending receiver immediately.
    public func enqueueText(_ text: String) {
        deliver(.success(.text(text)))
    }

    public func enqueueError(_ error: Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<RealtimeTransportFrame, Error>) {
        let waiter: CheckedContinuation<Result<RealtimeTransportFrame, Error>, Never>? = lock.withLock {
            if !awaiters.isEmpty {
                return awaiters.removeFirst()
            }
            inboundQueue.append(result)
            return nil
        }
        waiter?.resume(returning: result)
    }
}
