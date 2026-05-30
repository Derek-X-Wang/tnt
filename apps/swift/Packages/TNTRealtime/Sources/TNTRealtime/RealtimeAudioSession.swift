// RealtimeAudioSession — the single full-duplex audio path for a Voice
// Turn. Owns ONE `AVAudioEngine` that does both mic capture and speaker
// playback, with VoiceProcessingIO enabled on the input node for built-in
// echo cancellation + AGC (ADR-0002).
//
// Why one engine: VoiceProcessingIO is a single *full-duplex* AudioUnit —
// it owns the mic AND the speaker because it needs the render (output)
// signal as the echo reference. Two independent engines fight over the
// audio HAL and produce -10875 / KeystrokeSuppressor / HALC-overload
// failures and no audio.
//
// Two distinct formats, deliberately NOT shared:
//   * captureFormat  = PCM16 24 kHz mono — what the OpenAI Realtime API
//                      ingests (`input_audio_buffer.append`). The capture
//                      converter targets this.
//   * playbackFormat = Float32 24 kHz mono (the engine's standard format)
//                      — what `AVAudioPlayerNode` → `mainMixerNode` → the
//                      hardware output actually accept. Connecting the
//                      player with the Int16 capture format instead throws
//                      -10875 (kAudioUnitErr_FormatNotSupported) at
//                      engine start. Incoming PCM16 deltas are converted
//                      to Float32 before scheduling.

import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "com.derekxwang.tnt", category: "audio")

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
    /// Float32 deinterleaved — the engine/mixer/hardware-native format.
    private let playbackFormat: AVAudioFormat
    /// PCM16 interleaved — what the Realtime API expects on the wire.
    private let captureFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var pendingBytes = Data()

    private var engineStarted = false
    private var capturing = false
    /// Outstanding playback buffers scheduled but not yet finished. Lets
    /// `requestStopWhenDrained` wait for the reply audio to finish before
    /// releasing the mic.
    private var outstandingPlaybackBuffers = 0
    /// When true, stop the engine (releasing the mic) as soon as playback
    /// drains and capture is off — so the macOS mic-in-use indicator goes
    /// off between turns instead of staying lit by the warm VPIO input.
    private var stopWhenDrained = false
    private let lock = NSLock()

    public init(format: FrameFormat = .realtimeDefault) {
        self.format = format

        var resolved: AsyncStream<Data>.Continuation!
        self.frames = AsyncStream<Data> { resolved = $0 }
        self.continuation = resolved

        guard let playback = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels)
        ) else {
            fatalError("Unsupported playback format Float32 \(format.sampleRate) Hz")
        }
        self.playbackFormat = playback

        guard let capture = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            fatalError("Unsupported capture format PCM16 \(format.sampleRate) Hz")
        }
        self.captureFormat = capture
    }

    // MARK: - Engine lifecycle

    /// Lazily configure + start the shared engine. Enables VPIO on the
    /// input node (best-effort: if the machine has no usable input device
    /// we continue without echo cancellation rather than failing the whole
    /// Voice Turn), attaches the player to the mixer in the Float32 format
    /// the mixer accepts, and starts playback.
    private func ensureEngineStarted() throws {
        if lock.withLock({ engineStarted }) { return }
        // New activity cancels any pending drain-stop request.
        lock.withLock { stopWhenDrained = false }

        let input = engine.inputNode

        // Attach the player + connect it to the mixer exactly once, ever.
        // `stop()` (between turns) stops processing but keeps the graph, so
        // on a lazy restart the node is still attached+connected — and
        // re-attaching an already-attached node is a fatal programmer error.
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }

        // Try with VoiceProcessingIO (echo cancellation + AGC) first.
        // VPIO is a full-duplex AudioUnit and on some Macs makes
        // `engine.start()` fail with -10875 (FormatNotSupported) when the
        // hardware I/O format doesn't line up. If that happens, fall back
        // to a plain engine without voice processing — losing echo
        // cancellation but keeping working audio (ADR-0002 prefers VPIO
        // but does not require it).
        try? input.setVoiceProcessingEnabled(true)
        do {
            try engine.start()
            audioLog.info("engine started with VoiceProcessingIO")
        } catch {
            audioLog.error("engine.start with VPIO failed (\(error.localizedDescription, privacy: .public)) — retrying without voice processing")
            engine.stop()
            try? input.setVoiceProcessingEnabled(false)
            try engine.start()
            audioLog.info("engine started without VoiceProcessingIO (no echo cancellation)")
        }
        player.play()

        lock.withLock { engineStarted = true }
    }

    // MARK: - Capture (mic → frames)

    /// Begin forwarding mic audio as PCM16 `frames`. Idempotent. Starts
    /// the shared engine if it isn't running yet.
    public func startCapture() throws {
        try ensureEngineStarted()

        if lock.withLock({ capturing }) { return }

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        audioLog.info("capture native format: \(nativeFormat.sampleRate, privacy: .public)Hz ch=\(nativeFormat.channelCount, privacy: .public) common=\(nativeFormat.commonFormat.rawValue, privacy: .public) interleaved=\(nativeFormat.isInterleaved, privacy: .public)")

        guard let converter = AVAudioConverter(from: nativeFormat, to: captureFormat) else {
            throw AudioCaptureError.formatMismatch("Could not build converter from \(nativeFormat) to \(captureFormat).")
        }
        // Multichannel mics (5-channel aggregate/interface devices are
        // common) break AVAudioConverter's implicit N→1 downmix — it emits
        // silence for >2 input channels. Pin the single mono output channel
        // to input channel 0 (the conventional primary mic) so we capture
        // real audio instead of zeros.
        if nativeFormat.channelCount > 1 {
            converter.channelMap = [0]
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

    /// Schedule a PCM16 24 kHz mono frame for playback, converting it to
    /// the engine's Float32 format first. Starts the shared engine if
    /// needed. Buffers play in arrival order.
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

        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        guard let dst = buffer.floatChannelData?[0] else { return }
        let scale: Float = 1.0 / 32768.0
        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                dst[i] = Float(src[i]) * scale
            }
        }
        lock.withLock { outstandingPlaybackBuffers += 1 }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            let shouldStop: Bool = self.lock.withLock {
                self.outstandingPlaybackBuffers -= 1
                return self.stopWhenDrained
                    && self.outstandingPlaybackBuffers == 0
                    && !self.capturing
            }
            // Completion fires on a CoreAudio thread; engine teardown must
            // hop to the main queue.
            if shouldStop {
                DispatchQueue.main.async { self.stop() }
            }
        }
    }

    /// Release the engine (and the mic) once the reply audio finishes
    /// playing and capture is off. Stops immediately if nothing is
    /// pending. Called when a Voice Turn returns to idle so the macOS
    /// mic-in-use indicator clears between turns instead of staying lit
    /// by the warm VPIO input. The next turn lazily restarts the engine.
    public func requestStopWhenDrained() {
        let stopNow: Bool = lock.withLock {
            guard engineStarted else { return false }
            stopWhenDrained = true
            return outstandingPlaybackBuffers == 0 && !capturing
        }
        if stopNow { stop() }
    }

    /// Decode a base64 chunk straight from the WS event into the playback
    /// queue. Most callers receive base64.
    public func enqueueBase64(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        enqueue(pcmData: data)
    }

    /// Drop all queued + playing audio immediately (barge-in). Does not
    /// stop the engine.
    public func flushPlayback() {
        player.stop()
    }

    /// Re-arm the player after a `flushPlayback()`. `enqueue` also
    /// self-arms, so this mostly mirrors the flow's `restartPlayer`.
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
            stopWhenDrained = false
            outstandingPlaybackBuffers = 0
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

        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: outCapacity) else { return }

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

        let byteCount = Int(outBuffer.frameLength) * Int(captureFormat.channelCount) * MemoryLayout<Int16>.size
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
