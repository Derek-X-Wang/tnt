// RealtimeAudioSession — the single full-duplex audio path for a Voice
// Turn. Owns ONE `AVAudioEngine` that does both mic capture and speaker
// playback, with VoiceProcessingIO enabled on the input node for built-in
// echo cancellation + AGC (ADR-0002).
//
// Why one engine (this is the whole point of the file):
//   VoiceProcessingIO is a single *full-duplex* AudioUnit — it owns the
//   mic AND the speaker because it needs the render (output) signal as
//   the reference to cancel echo. Running a second, independent
//   `AVAudioEngine` for output alongside a VPIO input engine makes the
//   two fight over the audio HAL. On real hardware that surfaces as:
//       KeystrokeSuppressorCore … AU will be bypassed
//       vpStrategyManager … GetProperty error
//       throwing -10877            (kAudioUnitErr_InvalidElement)
//       HALC_ProxyIOContext … skipping cycle due to overload
//   and no audio is produced. Folding capture + playback onto one engine
//   removes the contention. (M0 hardware-verification finding.)
//
// Pipeline:
//   mic → VPIO input node → tap (hardware format)
//       → AVAudioConverter (→ PCM16 24 kHz mono)
//       → byte-accumulator (exactly `bytesPerFrame` per stream element)
//       → `frames` AsyncStream<Data>
//
//   response.audio.delta (base64 PCM16 24 kHz) → player node
//       → mainMixerNode (converts to the hardware's native format)
//       → output
//
// The player connects to `mainMixerNode`, NOT `outputNode`: the output
// node only accepts the hardware's native float format, so scheduling
// Int16 buffers straight onto it also throws -10877. The mixer does the
// format conversion for us.

import AVFoundation
import Foundation

/// Setup failures for the audio session. Only `formatMismatch` is
/// reachable today (the audio-unit converter could not be built); kept as
/// an enum so the surfaced message stays structured.
public enum AudioCaptureError: Error, Equatable, Sendable {
    case formatMismatch(String)
}

public final class RealtimeAudioSession: @unchecked Sendable {

    public let format: FrameFormat
    public let frames: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var pendingBytes = Data()

    private var engineStarted = false
    private var capturing = false
    private let lock = NSLock()

    public init(format: FrameFormat = .realtimeDefault) {
        self.format = format

        var resolved: AsyncStream<Data>.Continuation!
        self.frames = AsyncStream<Data> { resolved = $0 }
        self.continuation = resolved

        guard let pb = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            fatalError("Unsupported playback format PCM16 \(format.sampleRate) Hz")
        }
        self.playbackFormat = pb
    }

    // MARK: - Engine lifecycle

    /// Lazily configure + start the shared engine. Enables VPIO on the
    /// input node (best-effort: if the machine has no usable input device
    /// we continue without echo cancellation rather than failing the whole
    /// Voice Turn), attaches the player to the mixer, and starts playback.
    private func ensureEngineStarted() throws {
        if lock.withLock({ engineStarted }) { return }

        let input = engine.inputNode
        // Best-effort echo cancellation + AGC. A throw here means no input
        // device; playback-only turns (e.g. the debug WS round-trip) still
        // want the engine, so we swallow it and press on.
        try? input.setVoiceProcessingEnabled(true)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

        engine.prepare()
        try engine.start()
        player.play()

        lock.withLock { engineStarted = true }
    }

    // MARK: - Capture (mic → frames)

    /// Begin forwarding mic audio as `frames`. Idempotent. Starts the
    /// shared engine if it isn't running yet.
    public func startCapture() throws {
        try ensureEngineStarted()

        if lock.withLock({ capturing }) { return }

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        // Capture target == playback format: both are the canonical PCM16
        // 24 kHz mono the Realtime API speaks, so reuse the one already
        // built in `init` instead of constructing a byte-identical twin.
        guard let converter = AVAudioConverter(from: nativeFormat, to: playbackFormat) else {
            throw AudioCaptureError.formatMismatch("Could not build converter from \(nativeFormat) to \(playbackFormat).")
        }
        self.converter = converter

        let tapBufferSize = AVAudioFrameCount(
            nativeFormat.sampleRate * Double(format.frameDurationMs) / 1000.0
        )
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        lock.withLock {
            pendingBytes.removeAll(keepingCapacity: true)
            capturing = true
        }
    }

    /// Stop forwarding mic audio. The shared engine keeps running so any
    /// in-flight playback continues; only the tap is removed.
    public func stopCapture() {
        let wasCapturing: Bool = lock.withLock {
            let was = capturing
            capturing = false
            pendingBytes.removeAll(keepingCapacity: true)
            return was
        }
        guard wasCapturing else { return }

        engine.inputNode.removeTap(onBus: 0)
        converter = nil
    }

    // MARK: - Playback (deltas → speaker)

    /// Schedule a PCM16 24 kHz mono frame for playback, starting the
    /// shared engine if needed. Buffers play in arrival order.
    public func enqueue(pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        do {
            try ensureEngineStarted()
        } catch {
            return
        }
        // A prior `flushPlayback()` stops the player node; re-arm it so
        // freshly scheduled buffers actually sound.
        if !player.isPlaying {
            player.play()
        }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        guard let dst = buffer.int16ChannelData?[0] else { return }
        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                dst[i] = src[i]
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Decode a base64 chunk straight from the WS event into the playback
    /// queue. Most callers receive base64.
    public func enqueueBase64(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        enqueue(pcmData: data)
    }

    /// Drop all queued + playing audio immediately. Used for barge-in:
    /// when the user interrupts while TNT is speaking, the half-spoken
    /// reply must stop at once. Does not stop the engine.
    public func flushPlayback() {
        player.stop()
    }

    /// Re-arm the player after a `flushPlayback()` so the next enqueue
    /// sounds. `enqueue` also self-arms, so this is mostly a no-op kept
    /// to match the flow's `restartPlayer` directive.
    public func resumePlayback() {
        guard lock.withLock({ engineStarted }) else { return }
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Teardown

    /// Full teardown: remove the tap, stop the player, stop the engine,
    /// disable VPIO. The session can be started again afterwards.
    public func stop() {
        let wasStarted: Bool = lock.withLock {
            let was = engineStarted
            engineStarted = false
            capturing = false
            pendingBytes.removeAll(keepingCapacity: true)
            return was
        }
        guard wasStarted else { return }

        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        converter = nil
    }

    // MARK: - Internal

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = playbackFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: outCapacity) else { return }

        var fed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, statusOut in
            if fed {
                statusOut.pointee = .noDataNow
                return nil
            }
            fed = true
            statusOut.pointee = .haveData
            return buffer
        }
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil || outBuffer.frameLength == 0 { return }

        let byteCount = Int(outBuffer.frameLength) * Int(playbackFormat.channelCount) * MemoryLayout<Int16>.size
        guard let raw = outBuffer.int16ChannelData?[0] else { return }
        emitChunked(Data(bytes: raw, count: byteCount))
    }

    private func emitChunked(_ chunk: Data) {
        let toYield: [Data] = lock.withLock {
            guard capturing else { return [] }
            pendingBytes.append(chunk)

            let frameSize = format.bytesPerFrame
            var out: [Data] = []
            while pendingBytes.count >= frameSize {
                out.append(Data(pendingBytes.prefix(frameSize)))
                pendingBytes.removeFirst(frameSize)
            }
            return out
        }
        for frame in toYield {
            continuation.yield(frame)
        }
    }
}
