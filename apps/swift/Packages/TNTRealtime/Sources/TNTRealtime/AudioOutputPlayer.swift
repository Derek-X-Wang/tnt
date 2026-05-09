// AudioOutputPlayer — plays back the PCM16 24 kHz mono audio that
// arrives in `response.audio.delta` events. Schedules incoming buffers
// on an `AVAudioPlayerNode` connected to the engine's output node so
// deltas play in arrival order with no audible gaps (per M0/S7
// acceptance).
//
// Lifecycle:
//   start() → engine started → player.play()
//   enqueue(pcmData:) → schedule on player
//   stop() → tear down

import AVFoundation
import Foundation

public final class AudioOutputPlayer: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var started = false
    private let lock = NSLock()

    public init(sampleRate: Double = 24_000, channels: AVAudioChannelCount = 1) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: true
        ) else {
            fatalError("Unsupported audio output format")
        }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.outputNode, format: format)
    }

    public func start() throws {
        let already = lock.withLock { started }
        guard !already else { return }

        engine.prepare()
        try engine.start()
        player.play()
        lock.withLock { started = true }
    }

    public func stop() {
        let wasStarted = lock.withLock {
            let was = started
            started = false
            return was
        }
        guard wasStarted else { return }
        player.stop()
        engine.stop()
    }

    /// Schedule a PCM16 frame for playback. Buffers play in arrival
    /// order; the player handles its own underrun behaviour.
    public func enqueue(pcmData: Data) {
        guard !pcmData.isEmpty else { return }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        guard let dst = buffer.int16ChannelData?[0] else { return }
        pcmData.withUnsafeBytes { rawBuffer in
            let src = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                dst[i] = src[i]
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Decode a base64 chunk straight from the WS event into the
    /// playback queue. Helper because most callers receive base64.
    public func enqueueBase64(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        enqueue(pcmData: data)
    }
}
