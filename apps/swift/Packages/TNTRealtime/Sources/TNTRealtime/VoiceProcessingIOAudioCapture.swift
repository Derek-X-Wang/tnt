// VoiceProcessingIOAudioCapture — production `AudioCapture`. Uses
// `AVAudioEngine` with the VoiceProcessingIO AudioUnit (enabled via
// `AVAudioInputNode.setVoiceProcessingEnabled(true)`) to get built-in
// echo cancellation, AGC, and noise suppression — see ADR-0002 for why
// VPIO over WebRTC.
//
// Pipeline:
//   mic → input node tap (hardware-native format)
//        ↓
//   AVAudioConverter (→ 24 kHz Int16 mono)
//        ↓
//   byte-accumulator (yields exactly `bytesPerFrame` per stream tick)
//        ↓
//   `frames` AsyncStream<Data>
//
// Idempotent `start` / `stop` per the `AudioCapture` contract.

import AVFoundation
import Foundation

public final class VoiceProcessingIOAudioCapture: AudioCapture, @unchecked Sendable {

    public let format: FrameFormat
    public let frames: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private let engine: AVAudioEngine
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pendingBytes: Data = Data()
    private var running: Bool = false
    private let lock = NSLock()

    public init(format: FrameFormat = .realtimeDefault) {
        self.format = format
        self.engine = AVAudioEngine()

        var resolvedContinuation: AsyncStream<Data>.Continuation!
        self.frames = AsyncStream<Data> { cont in
            resolvedContinuation = cont
        }
        self.continuation = resolvedContinuation
    }

    public func start() async throws {
        if lock.withLock({ running }) {
            return
        }

        let input = engine.inputNode

        // Enable VoiceProcessingIO so we get built-in echo cancellation
        // + AGC. macOS may throw if no input is available; surface as
        // `microphoneUnavailable`.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw AudioCaptureError.microphoneUnavailable
        }

        let nativeFormat = input.outputFormat(forBus: 0)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else {
            throw AudioCaptureError.formatMismatch("Could not build PCM16 \(format.sampleRate) Hz target format.")
        }
        guard let converter = AVAudioConverter(from: nativeFormat, to: target) else {
            throw AudioCaptureError.formatMismatch("Could not build converter from \(nativeFormat) to \(target).")
        }
        self.converter = converter
        self.targetFormat = target

        let tapBufferSize = AVAudioFrameCount(
            nativeFormat.sampleRate * Double(format.frameDurationMs) / 1000.0
        )

        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nativeFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }

        lock.withLock { running = true }
    }

    public func stop() async {
        let wasRunning: Bool = lock.withLock {
            let was = running
            running = false
            pendingBytes.removeAll(keepingCapacity: true)
            return was
        }

        guard wasRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        converter = nil
        targetFormat = nil
    }

    // MARK: - Internal

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter, let target = targetFormat else { return }

        // Allocate an output buffer that can hold the converted frames.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            return
        }

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

        let byteCount = Int(outBuffer.frameLength) * Int(target.channelCount) * MemoryLayout<Int16>.size
        guard let raw = outBuffer.int16ChannelData?[0] else { return }
        let appended = Data(bytes: raw, count: byteCount)

        emitChunked(appended)
    }

    private func emitChunked(_ chunk: Data) {
        let framesToYield: [Data] = lock.withLock {
            guard running else { return [] }
            pendingBytes.append(chunk)

            let frameSize = format.bytesPerFrame
            var out: [Data] = []
            while pendingBytes.count >= frameSize {
                let frame = pendingBytes.prefix(frameSize)
                out.append(Data(frame))
                pendingBytes.removeFirst(frameSize)
            }
            return out
        }

        for frame in framesToYield {
            continuation.yield(frame)
        }
    }
}
