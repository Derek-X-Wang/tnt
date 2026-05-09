// AudioCapture — the protocol the Voice Provider uses to drain mic
// audio into a frame stream. Production impl is
// `VoiceProcessingIOAudioCapture`. `StubAudioCapture` exists for tests
// + UI demos so the SwiftUI surface can render the menu-bar VU
// indicator without instantiating `AVAudioEngine`.
//
// `start()` is idempotent — repeated calls while running are a no-op.
// `stop()` is idempotent — repeated calls while stopped are a no-op.
// The stream is hot once `start()` succeeds and goes idle on `stop()`.

import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case microphoneUnavailable
    case formatMismatch(String)
    case engineFailed(String)
}

public protocol AudioCapture: AnyObject, Sendable {
    /// Start the engine. Idempotent.
    func start() async throws

    /// Stop the engine. Idempotent. Frame stream goes silent.
    func stop() async

    /// Hot frame stream, framed per the implementation's `format`.
    var frames: AsyncStream<Data> { get }

    /// Frame format this implementation produces. Voice Provider
    /// callers may need it to size base64 buffers up-front.
    var format: FrameFormat { get }
}

/// In-memory stub used by tests and SwiftUI previews. Never touches
/// real hardware. Call `emit(_:)` to push synthetic frames into the
/// stream.
public final class StubAudioCapture: AudioCapture, @unchecked Sendable {

    public let format: FrameFormat
    public let frames: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private var running: Bool = false
    private let lock = NSLock()

    public init(format: FrameFormat = .realtimeDefault) {
        self.format = format
        var resolvedContinuation: AsyncStream<Data>.Continuation!
        self.frames = AsyncStream<Data> { cont in
            resolvedContinuation = cont
        }
        self.continuation = resolvedContinuation
    }

    public var isRunning: Bool {
        lock.withLock { running }
    }

    public func start() async throws {
        lock.withLock { running = true }
    }

    public func stop() async {
        lock.withLock { running = false }
    }

    /// Inject a frame into the stream. No-op when not running so tests
    /// can verify the gate behaves correctly.
    public func emit(_ data: Data) {
        let isRunning = lock.withLock { running }
        guard isRunning else { return }
        continuation.yield(data)
    }
}
