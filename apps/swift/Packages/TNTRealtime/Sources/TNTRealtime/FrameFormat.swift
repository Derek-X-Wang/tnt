// FrameFormat — frame-size math for the OpenAI Realtime PCM16 24 kHz
// mono pipeline. Pure value type so the Voice Provider's downstream
// math (per-frame allocation budgets, base64 chunking, WS payload
// upper bounds) stays trivially testable without instantiating
// `AVAudioEngine`.

import Foundation

public struct FrameFormat: Sendable, Equatable {

    public let sampleRate: Int
    public let channels: Int
    public let frameDurationMs: Int

    public init(sampleRate: Int, channels: Int, frameDurationMs: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameDurationMs = frameDurationMs
    }

    public var samplesPerFrame: Int {
        sampleRate * frameDurationMs / 1000
    }

    /// PCM16 = 2 bytes per sample per channel.
    public var bytesPerFrame: Int {
        samplesPerFrame * channels * 2
    }

    /// Length of a base64-encoded frame, including padding. The OpenAI
    /// Realtime WS path will need this for `input_audio_buffer.append`.
    public var base64LengthPerFrame: Int {
        ((bytesPerFrame + 2) / 3) * 4
    }

    /// Per-second pacing helper — mostly useful for sanity checks at
    /// development time.
    public var framesPerSecond: Int {
        1000 / frameDurationMs
    }

    /// OpenAI Realtime canonical: PCM16 mono 24 kHz, 80ms framing.
    public static let realtimeDefault: FrameFormat = FrameFormat(
        sampleRate: 24_000,
        channels: 1,
        frameDurationMs: 80
    )
}
