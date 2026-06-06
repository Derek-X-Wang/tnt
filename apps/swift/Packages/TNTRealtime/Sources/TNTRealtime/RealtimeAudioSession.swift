// RealtimeAudioSession — the single audio path for a Voice Turn. Owns ONE
// `AVAudioEngine` that does both mic capture (plain HAL input) and speaker
// playback (`AVAudioPlayerNode` → mixer → output).
//
// Why no VoiceProcessingIO (ADR-0002 amendment, 2026-06, issue #73):
// VPIO gives hardware echo cancellation + AGC, but as a system "voice chat"
// unit it DUCKS all other audio system-wide for the entire time the engine
// is alive — measured on hardware: with VPIO the user's YouTube/Music went
// SILENT; with plain HAL it stays full volume. TNT's Voice Turn is sequential
// (listen → think → speak), so the mic is not open while the reply plays;
// hardware echo cancellation only mattered for barge-in on OPEN speakers, a
// narrow case the Realtime server-side VAD tolerates. Dropping VPIO is the
// right trade: never silence the user's media, at the cost of AEC on that one
// path. (It does NOT change the ~1.7s first-press-after-idle cold start —
// that is mic-hardware wake, which plain HAL pays too; see #73.)
//
// Why one engine is still fine: a single PLAIN engine does simultaneous
// capture + playback without issue (measured: capture frames + playback tone
// at once, no -10875). The two-engines-fight-the-HAL failure (-10875 /
// KeystrokeSuppressor / HALC-overload) was specific to two *VPIO* full-duplex
// units; one plain engine is safe.
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

    /// Lazily configure + start the shared engine. Uses a PLAIN HAL input
    /// node (NO VoiceProcessingIO — see the "Why no VPIO" note at the top of
    /// this file and ADR-0002's 2026-06 amendment), attaches the player to
    /// the mixer in the Float32 format the mixer accepts, and starts playback.
    ///
    /// One plain engine does both mic capture and speaker playback
    /// simultaneously — measured working on hardware (capture + playback at
    /// once, no -10875). The two-engines-fight-the-HAL failure mode is
    /// specific to two *VPIO* full-duplex units; a single plain engine is fine.
    private func ensureEngineStarted() throws {
        if lock.withLock({ engineStarted }) { return }
        // New activity cancels any pending drain-stop request.
        lock.withLock { stopWhenDrained = false }

        // Attach the player + connect it to the mixer exactly once, ever.
        // Between turns the engine is PAUSED (`pauseForIdle`), not stopped, so
        // the graph + node stay intact and `engine.start()` below resumes warm.
        // Even after a full `stop()` the graph survives, so on any lazy restart
        // the node is still attached+connected — and re-attaching an
        // already-attached node is a fatal programmer error.
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }

        // Reference the input node BEFORE start(). This is load-bearing:
        // AVAudioEngine only opens the hardware INPUT device if the input
        // node has been realized before `start()`; otherwise it starts
        // output-only and the mic never opens (capture yields 0 frames, no
        // mic indicator). The old code touched the input node via
        // `setVoiceProcessingEnabled` here, which incidentally realized it —
        // dropping VPIO removed that side effect, so we realize it explicitly.
        // (Reproduced + verified on hardware: no input-node ref before start
        // → 0 frames; with this ref → frames flow. Issue #73.)
        _ = engine.inputNode

        // Plain HAL capture — no VoiceProcessingIO. VPIO's system-wide
        // ducking silenced the user's other audio (YouTube/Music) for the
        // whole time the engine was alive (measured: VPIO default = other
        // audio SILENT; plain HAL = full volume). For TNT's sequential
        // listen→speak Voice Turn the mic is not open while the reply plays,
        // so hardware echo cancellation buys nothing on the common path; the
        // only case it helped was barge-in on OPEN speakers, a narrow
        // scenario the Realtime server-side VAD tolerates. See ADR-0002
        // amendment (2026-06) + issue #73.
        try engine.start()
        audioLog.info("engine started (plain HAL capture, no voice processing)")
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
            let shouldPause: Bool = self.lock.withLock {
                self.outstandingPlaybackBuffers -= 1
                return self.stopWhenDrained
                    && self.outstandingPlaybackBuffers == 0
                    && !self.capturing
            }
            // Completion fires on a CoreAudio thread; engine teardown must
            // hop to the main queue.
            if shouldPause {
                DispatchQueue.main.async { self.pauseForIdle() }
            }
        }
    }

    /// Release the mic between Voice Turns once the reply audio finishes
    /// playing and capture is off — PAUSING (not fully stopping) the engine.
    /// Called when a Voice Turn returns to idle. Pausing clears the macOS
    /// mic-in-use indicator (verified: orange dot off) and frees other-app
    /// audio, BUT keeps the audio device warm so the next turn's
    /// `engine.start()` resumes in ~tens of ms instead of paying the ~1.7s
    /// cold device-open (measured: 70-270ms warm vs 1700ms cold; issue #73).
    /// Full release (`stop()`) is reserved for app teardown.
    public func requestStopWhenDrained() {
        let pauseNow: Bool = lock.withLock {
            guard engineStarted else { return false }
            stopWhenDrained = true
            return outstandingPlaybackBuffers == 0 && !capturing
        }
        if pauseNow { pauseForIdle() }
    }

    /// Pause the engine between turns: remove the tap, stop the player, and
    /// `engine.pause()` (NOT `stop()`). Keeps the device warm for a fast
    /// next-turn resume while clearing the mic indicator. `ensureEngineStarted`
    /// resumes a paused engine via `engine.start()` (warm). Idempotent.
    private func pauseForIdle() {
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
        engine.pause()
        converter = nil
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

    /// Full teardown: remove the tap, stop the player, stop the engine.
    /// The session can be started again afterwards.
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
