// RealtimeAudioSession — the audio path for a Voice Turn.
//
// CAPTURE and PLAYBACK are now SEPARATE units (issue #136 / #141 / #142):
//   • Capture: raw CoreAudio AUHAL (CoreAudioInputUnit) → CaptureFloatRing →
//     NativeCapturePipeline → `frames`. macOS-only. This replaces the old
//     AVAudioEngine.installTap capture, which silently zombied (0 frames) after
//     a long idle and blocked ~5s on inputNode.outputFormat(forBus:) — see the
//     #136 research. The AUHAL unit is kept initialized-but-stopped between
//     turns: warm device, instant start, mic indicator OFF between turns.
//   • Playback: AVAudioEngine + AVAudioPlayerNode (unchanged). Output was never
//     the problem; one plain output engine is fine.
//
// Because the two are independent, capture stops the instant the user stops
// speaking (stopCapture → AUHAL stop → mic dot off) while the reply keeps
// playing on the AVAudioEngine — this is the #77 fix, now structural.
//
// playbackFormat = Float32 24 kHz mono (the engine/mixer/hardware format).
// Incoming PCM16 deltas are converted to Float32 before scheduling.
//
// A zero-frame watchdog (CaptureControlCore) detects a dead capture turn (start
// ok but no buffers — denied permission, stuck device) and surfaces it via
// `captureStalled` so the Voice Turn layer can say "didn't catch that" instead
// of a silent dead turn.

import AVFoundation
import Foundation
import os

private let audioLog = Logger(subsystem: "com.derekxwang.tnt", category: "audio")

/// Setup failures for the audio session.
public enum AudioCaptureError: Error, Equatable, Sendable {
    case formatMismatch(String)
    case captureUnavailable
}

public final class RealtimeAudioSession: @unchecked Sendable {

    public let format: FrameFormat

    /// PCM16 24 kHz mono capture frames (unchanged public contract).
    public let frames: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    /// Fires when a capture turn produced no audio after recovery (#142/#77):
    /// the Voice Turn layer surfaces "didn't catch that" instead of a silent
    /// dead turn. Never fires on a normal turn.
    public let captureStalled: AsyncStream<Void>
    private let captureStalledContinuation: AsyncStream<Void>.Continuation

    // MARK: - Playback (AVAudioEngine)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat

    private var engineStarted = false
    private var outstandingPlaybackBuffers = 0
    private var stopWhenDrained = false
    private let lock = NSLock()

    // MARK: - Capture (AUHAL, macOS)

    private let ring = CaptureFloatRing(capacity: 48_000)   // ~1s @ 48 kHz headroom
    private let pipeline: NativeCapturePipeline
    private let control = CaptureControlCore(firstBufferDeadline: 0.6)
    /// Serializes the ENTIRE `drive()` body — control-core update AND the
    /// AudioUnit command execution — so concurrent callers (consumer tick,
    /// start/stopCapture, device listener) never mutate the unit at once.
    private let driveLock = NSLock()
    private let genLock = NSLock()
    private var captureConsumer: Task<Void, Never>?
    private var deviceGeneration = 0

    #if os(macOS)
    private var inputUnit: CoreAudioInputUnit?
    #endif

    public init(format: FrameFormat = .realtimeDefault) {
        self.format = format

        var resolvedFrames: AsyncStream<Data>.Continuation!
        self.frames = AsyncStream<Data> { resolvedFrames = $0 }
        self.continuation = resolvedFrames

        var resolvedStall: AsyncStream<Void>.Continuation!
        self.captureStalled = AsyncStream<Void> { resolvedStall = $0 }
        self.captureStalledContinuation = resolvedStall

        guard let playback = AVAudioFormat(
            standardFormatWithSampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels)
        ) else {
            fatalError("Unsupported playback format Float32 \(format.sampleRate) Hz")
        }
        self.playbackFormat = playback
        self.pipeline = NativeCapturePipeline(outputFormat: format)
    }

    // MARK: - Pre-warm

    /// Warm the mic device at launch so the first turn captures instantly.
    /// AUHAL: prepare() creates + initializes the unit and leaves it STOPPED —
    /// warm device, mic indicator off. Call off the main actor (prepare blocks
    /// briefly on the cold device open). No-op if capture is unavailable.
    public func prewarm() {
        #if os(macOS)
        ensureInputUnit()
        do {
            try inputUnit?.prepare()
            audioLog.info("prewarm: AUHAL mic warmed + stopped (first turn resumes warm)")
        } catch {
            audioLog.error("prewarm: AUHAL prepare failed (\(error.localizedDescription, privacy: .public)) — first turn pays cold open")
        }
        #endif
    }

    // MARK: - Capture (mic → frames)

    /// Begin capturing. Idempotent. Starts the AUHAL unit (preparing it warm if
    /// needed) and the off-thread consumer that drains ring → pipeline → frames.
    public func startCapture() throws {
        #if os(macOS)
        ensureInputUnit()
        ring.reset()
        pipeline.reset()
        startConsumerIfNeeded()
        drive(.startRequested(deviceID: currentDeviceKey(), now: Self.now()))
        #else
        throw AudioCaptureError.captureUnavailable
        #endif
    }

    /// Stop capturing the instant the user stops speaking. The AUHAL unit stops
    /// (mic indicator clears) but stays initialized (warm); playback continues
    /// on the AVAudioEngine for the reply. This is the #77 fix.
    public func stopCapture() {
        #if os(macOS)
        drive(.stopRequested)
        #endif
    }

    // MARK: - Playback (deltas → speaker)

    /// Schedule a PCM16 24 kHz mono frame for playback, converting to Float32.
    public func enqueue(pcmData: Data) {
        guard !pcmData.isEmpty else { return }
        do {
            try ensurePlaybackStarted()
        } catch {
            return
        }
        if !player.isPlaying { player.play() }

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
                return self.stopWhenDrained && self.outstandingPlaybackBuffers == 0
            }
            if shouldPause {
                DispatchQueue.main.async { self.pausePlaybackForIdle() }
            }
        }
    }

    /// Decode a base64 chunk straight from the WS event into the playback queue.
    public func enqueueBase64(_ base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        enqueue(pcmData: data)
    }

    /// Drop all queued + playing audio immediately (barge-in). Does not stop the engine.
    public func flushPlayback() {
        player.stop()
    }

    /// Re-arm the player after a `flushPlayback()`.
    public func resumePlayback() {
        guard lock.withLock({ engineStarted }) else { return }
        if !player.isPlaying { player.play() }
    }

    /// Pause the PLAYBACK engine once the reply audio finishes draining. Capture
    /// is a separate unit and is already stopped via `stopCapture()`, so this no
    /// longer governs the mic indicator (that clears at end-of-listening, #77).
    public func requestStopWhenDrained() {
        let pauseNow: Bool = lock.withLock {
            guard engineStarted else { return false }
            stopWhenDrained = true
            return outstandingPlaybackBuffers == 0
        }
        if pauseNow { pausePlaybackForIdle() }
    }

    // MARK: - Teardown

    /// Full teardown of both capture and playback. The session can start again.
    public func stop() {
        captureConsumer?.cancel()
        captureConsumer = nil
        #if os(macOS)
        // Serialize with `drive()` so teardown never races an in-flight command
        // executing on the unit from the consumer task.
        driveLock.lock()
        inputUnit?.teardown()
        driveLock.unlock()
        #endif
        ring.reset()
        pipeline.reset()

        let wasStarted: Bool = lock.withLock {
            let was = engineStarted
            engineStarted = false
            stopWhenDrained = false
            outstandingPlaybackBuffers = 0
            return was
        }
        if wasStarted {
            player.stop()
            engine.stop()
        }
    }

    // MARK: - Playback engine lifecycle

    private func ensurePlaybackStarted() throws {
        if lock.withLock({ engineStarted }) { return }
        lock.withLock { stopWhenDrained = false }

        // Attach + connect the player exactly once; the graph survives pause/stop.
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        }
        try engine.start()
        player.play()
        lock.withLock { engineStarted = true }
    }

    private func pausePlaybackForIdle() {
        let wasStarted: Bool = lock.withLock {
            let was = engineStarted
            engineStarted = false
            stopWhenDrained = false
            outstandingPlaybackBuffers = 0
            return was
        }
        guard wasStarted else { return }
        player.stop()
        engine.pause()
    }

    // MARK: - Capture orchestration (macOS)

    #if os(macOS)
    private func ensureInputUnit() {
        guard inputUnit == nil else { return }
        inputUnit = CoreAudioInputUnit(ring: ring) { [weak self] in
            // Default input device changed (off the RT thread). Bump generation
            // so the control core rebuilds on the next start.
            guard let self else { return }
            self.genLock.lock()
            self.deviceGeneration += 1
            let gen = self.deviceGeneration
            self.genLock.unlock()
            self.drive(.deviceChanged(generation: gen))
        }
    }

    private func currentDeviceKey() -> String {
        String(CoreAudioInputUnit.defaultInputDevice())
    }

    /// Single serialized entry point: feed one event to the control core and
    /// execute the resulting commands. Follow-up events (prepared/unitFailed)
    /// are appended to the same command pass — no recursion.
    private func drive(_ event: CaptureControlEvent) {
        driveLock.lock()
        defer { driveLock.unlock() }
        var cmds = control.update(event)

        var i = 0
        while i < cmds.count {
            let cmd = cmds[i]
            i += 1
            switch cmd {
            case .prepare(let dev):
                do {
                    try inputUnit?.prepare()
                    cmds.append(contentsOf: control.update(.prepared(deviceID: dev, now: Self.now())))
                } catch {
                    audioLog.error("capture prepare failed: \(error.localizedDescription, privacy: .public)")
                    cmds.append(contentsOf: control.update(.unitFailed))
                }
            case .start:
                do { try inputUnit?.start() }
                catch { audioLog.error("capture start failed: \(error.localizedDescription, privacy: .public)") }
            case .stop:
                inputUnit?.stop()
            case .reset:
                inputUnit?.teardown()
            case .rebuild:
                audioLog.info("capture: watchdog/device rebuild")
                inputUnit?.teardown()
                do {
                    try inputUnit?.prepare()
                    try inputUnit?.start()
                } catch {
                    audioLog.error("capture rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
            case .failTurn:
                audioLog.error("capture: zero-frame turn — surfacing stall")
                captureStalledContinuation.yield(())
            }
        }
    }

    private func startConsumerIfNeeded() {
        guard captureConsumer == nil else { return }
        captureConsumer = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let scratchCount = 8192
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
            defer { scratch.deallocate() }

            while !Task.isCancelled {
                let n = self.ring.read(into: scratch, maxCount: scratchCount)
                if n > 0 {
                    // Off the RT thread: wrap mono samples + convert/chunk.
                    let mono = Array(UnsafeBufferPointer(start: scratch, count: n))
                    self.pipeline.push(planes: [mono], frameCount: n, format: self.captureNativeFormat())
                    self.drive(.bufferArrived)
                    while let frame = self.pipeline.dequeue() {
                        self.continuation.yield(frame)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms idle poll
                }
                self.drive(.tick(now: Self.now()))
            }
        }
    }

    private func captureNativeFormat() -> NativeCaptureFormat {
        // Channel 0 is already extracted in the render callback, so the pipeline
        // sees a single mono plane at the device's native sample rate.
        let sr = inputUnit?.nativeSampleRate ?? 48_000
        return NativeCaptureFormat(
            sampleRate: sr, channelCount: 1, encoding: .float32, layout: .nonInterleaved)
    }
    #endif

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
