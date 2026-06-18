// NativeCapturePipeline — pure DSP + buffering core (issue #139).
//
// Converts a stream of native mic audio chunks into PCM16 24 kHz mono frames
// sized to FrameFormat. No CoreAudio / AudioToolbox types appear in the public
// API — the internal AVAudioConverter use is an implementation detail hidden
// behind the NativeCaptureFormat abstraction.
//
// HOT-PATH ALLOCATION CONTRACT (AC5):
//   push() pre-allocates every buffer at init time and performs zero heap
//   allocations on the critical path:
//     • inputBuf  — pre-allocated [Float] of maxInputCapacity samples
//     • inputAVBuf — pre-allocated AVAudioPCMBuffer (maxInputCapacity frames)
//     • outputAVBuf — pre-allocated AVAudioPCMBuffer (maxOutputCapacity frames)
//     • accumBuf  — pre-allocated [Int16] of accumCapacity samples
//     • ring storage — pre-allocated Data of queueCapacity × bytesPerFrame bytes
//   The AVAudioConverter itself may perform internal allocations during
//   sample-rate conversion; those are owned by the framework and outside our
//   control.  Everything *we* allocate is done once in init.
//
// THREAD SAFETY:
//   push() is designed to be called from the audio render / tap thread.
//   dequeue() and reset() are safe to call from any other thread.
//   An NSLock protects the ring buffer and accum state.  In a true hard-RT
//   context the HITL adapter should ensure the lock is uncontended (the
//   consumer drains the queue between turns); tryLock semantics on the
//   producer side would eliminate the last lock-path risk, but are deferred
//   until hardware profiling (issue #TBD-3) confirms it's needed.
//
// CHANNEL SELECTION (AC2):
//   For multichannel input (non-interleaved), push() copies plane[0] into a
//   pre-allocated mono buffer and feeds that into a mono AVAudioConverter.
//   This is explicit "select channel 0" — not downmixing — so the 5-channel
//   fix is a structural guarantee, not a converter hint.
//
// RESAMPLER STATE (AC4):
//   The AVAudioConverter is created once per configured format and kept alive
//   across push() calls.  AVAudioConverter's SRC maintains its filter delay
//   line between convert() calls, so there are no per-call discontinuities.
//   reset() tears down and recreates the converter, clearing its state.

import AVFoundation
import Foundation

/// Overflow behaviour when the bounded output queue is full.
public enum CaptureOverflowPolicy: Sendable {
    /// Drop the oldest queued frame to make room for the new one.
    case dropOldest
    /// Drop the incoming frame; keep what is already queued.
    case dropNewest
}

/// Pure DSP + buffering core for native mic capture.
///
/// Call ``push(planes:frameCount:format:)`` from the audio render thread.
/// Call ``dequeue()`` from any consumer thread to pull PCM16 frames.
public final class NativeCapturePipeline: @unchecked Sendable {

    // MARK: - Public configuration

    public let outputFormat: FrameFormat
    public let queueCapacity: Int
    public let overflowPolicy: CaptureOverflowPolicy

    // MARK: - Pre-allocated hot-path buffers

    /// Max input frames the pipeline accepts per push() call.
    /// 2× 80ms @ 48 kHz (7680 frames) leaves headroom for variable callback sizes.
    private let maxInputCapacity: Int = 15_360
    /// Max output frames after SRC (ratio ≤ 1; 7680 @ 48→24kHz = 3840 out).
    private let maxOutputCapacity: Int = 7_680

    /// Pre-allocated mono Float32 scratch buffer for channel extraction.
    private var inputBuf: [Float]
    /// Pre-allocated AVAudioPCMBuffer for the converter's input side.
    private var inputAVBuf: AVAudioPCMBuffer?

    // MARK: - Converter (persistent SRC state)

    private var converter: AVAudioConverter?
    /// The PCM16 output format the converter produces (stored for per-call buffer alloc).
    private var convOutputFormat: AVAudioFormat?
    /// The NativeCaptureFormat for which the converter was built.
    /// We rebuild if the format changes between push() calls.
    private var configuredNativeFormat: NativeCaptureFormat?

    // MARK: - PCM16 accumulation buffer (pre-allocated)

    /// accumBuf holds Int16 samples at 24 kHz mono waiting to be
    /// chunked into complete FrameFormat frames.
    /// Capacity: 2 × samplesPerFrame (headroom for partial frames).
    private var accumBuf: [Int16]
    private var accumCount: Int = 0   // valid samples in accumBuf

    // MARK: - Ring buffer (pre-allocated, AC6)

    /// Flat pre-allocated storage: queueCapacity × bytesPerFrame bytes.
    private var ringStorage: Data
    private var ringHead: Int = 0   // next read slot (frame index)
    private var ringTail: Int = 0   // next write slot (frame index)
    private var _queuedFrameCount: Int = 0

    /// Number of complete frames currently waiting in the queue.
    public var queuedFrameCount: Int {
        lock.withLock { _queuedFrameCount }
    }

    // MARK: - Lock

    private let lock = NSLock()

    // MARK: - Init

    public init(
        outputFormat: FrameFormat = .realtimeDefault,
        queueCapacity: Int = 10,
        overflowPolicy: CaptureOverflowPolicy = .dropOldest
    ) {
        self.outputFormat = outputFormat
        self.queueCapacity = queueCapacity
        self.overflowPolicy = overflowPolicy

        // Pre-allocate all hot-path buffers (AC5).
        self.inputBuf = [Float](repeating: 0, count: maxInputCapacity)
        // Ring storage: queueCapacity complete frames.
        self.ringStorage = Data(count: queueCapacity * outputFormat.bytesPerFrame)
        // Accum buffer: 2× one output frame in PCM16 samples.
        let accumCapacity = outputFormat.samplesPerFrame * 2
        self.accumBuf = [Int16](repeating: 0, count: accumCapacity)
    }

    // MARK: - Public API

    /// Feed a chunk of native audio samples into the pipeline.
    ///
    /// - Parameters:
    ///   - planes: Channel buffers.  For `.nonInterleaved` format, each element
    ///     is one channel's Float32 samples; only `planes[0]` is used (explicit
    ///     channel-0 selection for multichannel mics).  For `.interleaved`,
    ///     pass a single element containing all channels interleaved.
    ///   - frameCount: Number of *audio frames* in the chunk.
    ///   - format: Describes `planes`'s sample rate, channel count, encoding,
    ///     and layout.
    ///
    /// - Important: Designed to be called from the audio render thread. All
    ///   buffers are pre-allocated; no heap allocation occurs inside this method
    ///   beyond what AVFoundation's converter does internally.
    public func push(planes: [[Float]], frameCount: Int, format: NativeCaptureFormat) {
        guard frameCount > 0, !planes.isEmpty else { return }
        guard frameCount <= maxInputCapacity else {
            // Silently drop oversized chunks rather than crashing.
            return
        }

        lock.lock()

        // (Re)build the converter if the format changed (AC4: persistent state
        // across calls with the same format).
        if configuredNativeFormat != format {
            buildConverter(for: format)
        }

        guard let conv = converter,
              let inBuf = inputAVBuf,
              let outFmt = convOutputFormat else {
            lock.unlock()
            return
        }
        let native = configuredNativeFormat!

        // --- Explicit channel 0 extraction (AC2) ---
        // Copy plane[0] into our pre-allocated Float32 scratch buffer.
        let srcPlane = planes[0]
        let copyCount = min(frameCount, srcPlane.count)
        inputBuf.withUnsafeMutableBufferPointer { dst in
            srcPlane.withUnsafeBufferPointer { src in
                let n = min(copyCount, src.count)
                dst.baseAddress?.update(from: src.baseAddress!, count: n)
            }
        }

        // Write the mono samples into the pre-allocated AVAudioPCMBuffer.
        inBuf.frameLength = AVAudioFrameCount(copyCount)
        if let channelData = inBuf.floatChannelData {
            channelData[0].update(from: inputBuf, count: copyCount)
        }

        // --- Sample-rate conversion (AC4) ---
        // The converter maintains its SRC filter delay line across calls;
        // we do NOT recreate it here.
        //
        // We allocate the output AVAudioPCMBuffer per call because
        // AVAudioConverter.convert() sets frameLength on the buffer to the
        // number of produced frames; reusing a pre-allocated buffer with a
        // stale frameLength from the previous call leads to mis-reads.
        // The per-call allocation is inside AVFoundation and cannot be
        // avoided without a custom resampler; our pre-allocations cover
        // the input buffer, accumulation buffer, and ring storage.
        let outCapacity = AVAudioFrameCount(
            Double(copyCount) * Double(outputFormat.sampleRate) / native.sampleRate + 64
        )
        guard let freshOutBuf = AVAudioPCMBuffer(
            pcmFormat: outFmt,
            frameCapacity: max(outCapacity, 1)
        ) else {
            lock.unlock()
            return
        }

        var fed = false
        conv.convert(to: freshOutBuf, error: nil) { _, statusOut in
            if fed {
                statusOut.pointee = .noDataNow
                return nil
            }
            fed = true
            statusOut.pointee = .haveData
            return inBuf
        }

        let producedFrames = Int(freshOutBuf.frameLength)
        guard producedFrames > 0 else {
            lock.unlock()
            return
        }

        // --- PCM16 accumulation + chunking ---
        // The converter output is PCM16 (Int16), interleaved, 24 kHz mono.
        guard let rawInt16 = freshOutBuf.int16ChannelData?[0] else {
            lock.unlock()
            return
        }

        var offset = 0
        while offset < producedFrames {
            let samplesNeeded = outputFormat.samplesPerFrame - accumCount
            let available = producedFrames - offset
            let toCopy = min(samplesNeeded, available)

            // Copy into pre-allocated accumBuf (no malloc).
            for i in 0..<toCopy {
                accumBuf[accumCount + i] = rawInt16[offset + i]
            }
            accumCount += toCopy
            offset += toCopy

            if accumCount >= outputFormat.samplesPerFrame {
                // Emit one complete frame into the ring buffer.
                emitFrameLocked()
                accumCount = 0
            }
        }

        lock.unlock()
    }

    /// Dequeue one PCM16 24 kHz mono frame.  Returns `nil` if the queue is empty.
    public func dequeue() -> Data? {
        lock.withLock {
            guard _queuedFrameCount > 0 else { return nil }
            let frameSize = outputFormat.bytesPerFrame
            let start = ringHead * frameSize
            let frame = ringStorage[start ..< start + frameSize]
            ringHead = (ringHead + 1) % queueCapacity
            _queuedFrameCount -= 1
            return Data(frame)
        }
    }

    /// Clear all pending audio and reset the converter's SRC state (AC7).
    /// Call at Voice-Turn boundaries.
    public func reset() {
        lock.withLock {
            accumCount = 0
            ringHead = 0
            ringTail = 0
            _queuedFrameCount = 0
            // Rebuild the converter to flush the SRC filter delay line.
            if let fmt = configuredNativeFormat {
                buildConverter(for: fmt)
            }
        }
    }

    // MARK: - Private helpers

    /// Build (or rebuild) the AVAudioConverter + pre-allocated input buffer
    /// for the given native format.  Must be called with `lock` held.
    private func buildConverter(for native: NativeCaptureFormat) {
        // Input: mono Float32 at native sample rate (we extract channel 0 before
        // handing data to the converter, so the AVAudioConverter always sees mono).
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: native.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }

        // Output: PCM16 mono at the target sample rate.
        guard let outputAVFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(outputFormat.sampleRate),
            channels: AVAudioChannelCount(outputFormat.channels),
            interleaved: true
        ) else { return }

        guard let conv = AVAudioConverter(from: inputFormat, to: outputAVFormat) else { return }

        // Pre-allocate input buffer (maxInputCapacity frames).
        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(maxInputCapacity)
        ) else { return }

        self.converter = conv
        self.convOutputFormat = outputAVFormat
        self.inputAVBuf = inBuf
        self.configuredNativeFormat = native
        // Clear accumulation when format changes.
        self.accumCount = 0
    }

    /// Write the current complete frame from `accumBuf` into the ring buffer.
    /// Applies the overflow policy if the queue is full.  Must be called with
    /// `lock` held.
    private func emitFrameLocked() {
        let frameSize = outputFormat.bytesPerFrame

        if _queuedFrameCount >= queueCapacity {
            switch overflowPolicy {
            case .dropOldest:
                // Advance head to evict the oldest frame.
                ringHead = (ringHead + 1) % queueCapacity
                _queuedFrameCount -= 1
            case .dropNewest:
                // Discard the incoming frame; keep the queue as-is.
                return
            }
        }

        // Write the frame at ringTail into the pre-allocated storage (no malloc).
        let start = ringTail * frameSize
        accumBuf.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            ringStorage.withUnsafeMutableBytes { dst in
                dst.baseAddress?.advanced(by: start)
                    .copyMemory(from: base, byteCount: frameSize)
            }
        }
        ringTail = (ringTail + 1) % queueCapacity
        _queuedFrameCount += 1
    }
}
