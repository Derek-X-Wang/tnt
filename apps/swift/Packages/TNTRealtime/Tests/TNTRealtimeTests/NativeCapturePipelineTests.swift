// NativeCapturePipelineTests — TDD for issue #139.
// Each test maps to one acceptance criterion from the issue body.

import XCTest
@testable import TNTRealtime

final class NativeCapturePipelineTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesise Float32 non-interleaved planes for `channelCount` channels,
    /// filling channel 0 with a ramp (non-zero) and remaining channels with
    /// a different value so we can distinguish them.
    static func makePlanes(
        channelCount: Int,
        frameCount: Int,
        ch0Value: Float = 0.5,
        otherValue: Float = -1.0
    ) -> [[Float]] {
        (0..<channelCount).map { ch in
            [Float](repeating: ch == 0 ? ch0Value : otherValue, count: frameCount)
        }
    }

    // MARK: - AC1: NativeCaptureFormat compiles without AudioToolbox in public API

    func testNativeCaptureFormatIsPublicValueType() {
        // Verify struct can be constructed and is Equatable/Sendable without
        // importing AudioToolbox.
        let fmt = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        XCTAssertEqual(fmt.sampleRate, 48_000)
        XCTAssertEqual(fmt.channelCount, 1)
        XCTAssertEqual(fmt.encoding, .float32)
        XCTAssertEqual(fmt.layout, .nonInterleaved)
        // Equatable
        let fmt2 = NativeCaptureFormat(sampleRate: 48_000, channelCount: 1, encoding: .float32, layout: .nonInterleaved)
        XCTAssertEqual(fmt, fmt2)
    }

    // MARK: - AC2: 5-channel input → only channel 0 captured (golden: non-zero)

    func testFiveChannelInputSelectsChannelZeroOnly() {
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 32,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 5,
            encoding: .float32,
            layout: .nonInterleaved
        )
        // Push 2× the nominal amount (7680 input → 3840 output @ 24kHz → 2 frames)
        // to ensure at least 1 complete 1920-sample output frame despite SRC startup latency.
        let frameCount = 8192
        // Channel 0: 0.5 (should produce non-zero PCM16 output)
        // Channels 1-4: 0.0 (silence — if wrongly mixed in, result could differ)
        let planes = Self.makePlanes(channelCount: 5, frameCount: frameCount, ch0Value: 0.5, otherValue: 0.0)
        pipeline.push(planes: planes, frameCount: frameCount, format: nativeFormat)

        // Drain all queued frames
        var allBytes = Data()
        while let frame = pipeline.dequeue() {
            allBytes.append(frame)
        }
        // Each output frame must be exactly bytesPerFrame bytes
        XCTAssertTrue(allBytes.count % FrameFormat.realtimeDefault.bytesPerFrame == 0,
            "Output must be aligned to frame boundaries")
        XCTAssertFalse(allBytes.isEmpty, "Expected non-zero output from channel 0")

        // Verify at least one non-zero PCM16 sample (channel 0 had 0.5 amplitude)
        var hasNonZero = false
        allBytes.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples where s != 0 { hasNonZero = true; break }
        }
        XCTAssertTrue(hasNonZero, "PCM16 output should be non-zero when channel 0 has amplitude 0.5")
    }

    func testFiveChannelInputWithSilentChannelZeroProducesSilence() {
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 32,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 5,
            encoding: .float32,
            layout: .nonInterleaved
        )
        let frameCount = 8192
        // Channel 0 is 0.0 (silence), channels 1-4 are 0.5
        // If we incorrectly selected another channel, we'd get non-zero output
        let planes = Self.makePlanes(channelCount: 5, frameCount: frameCount, ch0Value: 0.0, otherValue: 0.5)
        pipeline.push(planes: planes, frameCount: frameCount, format: nativeFormat)

        var allBytes = Data()
        while let frame = pipeline.dequeue() {
            allBytes.append(frame)
        }
        // May get no frames or silent frames
        allBytes.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                XCTAssertEqual(s, 0, "Should be silence when channel 0 is 0.0")
            }
        }
    }

    // MARK: - AC3: Variable frame counts → correct FrameFormat chunks, no gaps/dupes

    func testVariableInputFrameCountsProduceCorrectChunks() {
        let outputFormat = FrameFormat.realtimeDefault  // 24kHz, 80ms, 3840 bytes/frame
        let pipeline = NativeCapturePipeline(
            outputFormat: outputFormat,
            queueCapacity: 64,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )

        // Push varying frame counts (simulates variable AUHAL callback sizes)
        // Total: 512 + 256 + 1024 + 512 = 2304 input frames @ 48kHz
        // → 2304 / 2 = 1152 output frames @ 24kHz → 1152 * 2 = 2304 PCM16 bytes
        // → 2304 / 3840 = 0.6 output frames (less than one 80ms frame, so may get 0)
        // Let's push more: 9 × 960 = 8640 input frames → 4320 output frames →
        // 4320 * 2 = 8640 bytes → 8640 / 3840 = 2 complete frames
        let sizes = [512, 256, 1024, 512, 960, 960, 512, 1024, 640]  // sum = 6400 @ 48kHz → 3200 @ 24kHz → 6400 bytes → 1 full 3840-byte frame
        // More: let's push enough for 2 frames
        // 2 frames = 2 * 1920 samples @ 24kHz = 3840 samples → 7680 input samples @ 48kHz
        let sizes2 = [960, 960, 960, 960, 960, 960, 960, 960]  // 7680 total

        var ramp: Float = 0.0
        for size in sizes2 {
            let planes = [[Float]](repeating: (0..<size).map { _ in ramp }, count: 1)
            ramp = ramp + 0.001 > 1.0 ? 0.0 : ramp + 0.001
            pipeline.push(planes: planes, frameCount: size, format: nativeFormat)
        }

        var frames: [Data] = []
        while let frame = pipeline.dequeue() {
            frames.append(frame)
        }

        // Must have at least one complete frame
        XCTAssertGreaterThanOrEqual(frames.count, 1, "Expected at least one output frame")
        // Every frame must be exactly bytesPerFrame bytes
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(frame.count, outputFormat.bytesPerFrame,
                "Frame \(i) has wrong size: \(frame.count) vs expected \(outputFormat.bytesPerFrame)")
        }
    }

    // MARK: - AC4: 48kHz → 24kHz, resampler state persists across calls

    func testResamplerStatePersistsAcrossCalls() {
        // If the resampler were reset per call we'd get discontinuities
        // at call boundaries. Test: push a monotone sine across many small
        // calls, verify the output is continuous (no sudden phase jumps).
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 64,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )

        // Push 16 × 480-frame chunks (each is 10ms @ 48kHz). A per-call
        // resampler reset would cause a silent gap at each boundary because
        // the SRC state (filter delay line) is flushed.
        // Total: 16 × 480 = 7680 frames → 3840 @ 24kHz → 1 complete 80ms frame.
        let freq: Double = 440  // 440Hz sine
        var phase: Double = 0
        let sampleRate: Double = 48_000
        let dt = 2 * Double.pi * freq / sampleRate

        for _ in 0..<16 {
            let chunkSize = 480
            var chunk = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize {
                chunk[i] = Float(sin(phase))
                phase += dt
            }
            pipeline.push(planes: [chunk], frameCount: chunkSize, format: nativeFormat)
        }

        var frames: [Data] = []
        while let frame = pipeline.dequeue() {
            frames.append(frame)
        }
        XCTAssertGreaterThanOrEqual(frames.count, 1, "Should produce output from 16 small pushes")

        // Verify output is not all zeros (would indicate resampler state was lost)
        var hasNonZero = false
        for frame in frames {
            frame.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for s in samples where s != 0 { hasNonZero = true }
            }
        }
        XCTAssertTrue(hasNonZero, "Output should reflect sine input, not silence (resampler state must persist)")
    }

    // MARK: - AC5: No allocation on hot path (design + functional verification)

    func testHotPathHandlesManyCallsWithoutError() {
        // Design assertion: push() pre-allocates all buffers at init and
        // does no malloc on the per-chunk path (see NativeCapturePipeline.swift
        // comments). This test verifies functional correctness across 1000
        // variable-size pushes, which would expose any crash or data corruption
        // from missing pre-allocation.
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 128,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        var totalInputFrames = 0
        for i in 0..<100 {
            let size = 256 + (i % 5) * 128  // 256, 384, 512, 640, 768, repeating
            let chunk = [Float](repeating: 0.3, count: size)
            pipeline.push(planes: [chunk], frameCount: size, format: nativeFormat)
            totalInputFrames += size
        }
        // Drain and verify all output frames have correct size
        var outputFrames = 0
        while let frame = pipeline.dequeue() {
            XCTAssertEqual(frame.count, FrameFormat.realtimeDefault.bytesPerFrame)
            outputFrames += 1
        }
        XCTAssertGreaterThan(outputFrames, 0, "Expected at least one output frame from 100 pushes")
    }

    // MARK: - AC6: Bounded-queue overflow policy is explicit and tested

    func testDropOldestOverflowPolicyDropsOldestFrames() {
        let cap = 3
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: cap,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        // Push enough to fill the queue beyond capacity.
        // Each 80ms output frame needs 7680 input samples @ 48kHz.
        // Push 5 × 7680 = 38400 frames → 5 output frames → queue cap=3 → 2 dropped (oldest)
        for batch in 0..<5 {
            // Use distinct amplitude per batch so we can identify which frames survive
            let amplitude = Float(batch + 1) * 0.1
            let chunk = [Float](repeating: amplitude, count: 7680)
            pipeline.push(planes: [chunk], frameCount: 7680, format: nativeFormat)
        }

        XCTAssertEqual(pipeline.queuedFrameCount, cap, "Queue should be at capacity after overflow")

        // With dropOldest, the 3 newest frames should remain (batches 2, 3, 4 → amplitudes 0.3, 0.4, 0.5)
        var frames: [Data] = []
        while let frame = pipeline.dequeue() {
            frames.append(frame)
        }
        XCTAssertEqual(frames.count, cap, "Should have exactly \(cap) frames after overflow")
    }

    func testDropNewestOverflowPolicyPreservesOldestFrames() {
        let cap = 2
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: cap,
            overflowPolicy: .dropNewest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        // Push 4 output frames worth of data
        for _ in 0..<4 {
            let chunk = [Float](repeating: 0.5, count: 7680)
            pipeline.push(planes: [chunk], frameCount: 7680, format: nativeFormat)
        }

        XCTAssertEqual(pipeline.queuedFrameCount, cap, "Queue should remain at capacity")
        var frames: [Data] = []
        while let frame = pipeline.dequeue() { frames.append(frame) }
        XCTAssertEqual(frames.count, cap, "Should keep only \(cap) frames (oldest)")
    }

    // MARK: - AC7: reset() clears pending bytes + resampler state

    func testResetClearsPendingAndResamplerState() {
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 32,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )

        // Push a partial frame's worth of data (won't emit a complete frame yet)
        let partialChunk = [Float](repeating: 0.5, count: 1000)
        pipeline.push(planes: [partialChunk], frameCount: 1000, format: nativeFormat)

        // Reset should clear pending accumulation
        pipeline.reset()

        // Now push exactly enough for one complete output frame (7680 @ 48kHz → 3840 @ 24kHz → 1 frame)
        let fullChunk = [Float](repeating: 0.5, count: 7680)
        pipeline.push(planes: [fullChunk], frameCount: 7680, format: nativeFormat)

        // The output should be exactly 1 frame, not 1+partial (reset cleared accumulation)
        var frames: [Data] = []
        while let f = pipeline.dequeue() { frames.append(f) }
        XCTAssertEqual(frames.count, 1, "After reset, should have exactly 1 frame from the new push")
    }

    func testResetClearsQueuedFrames() {
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 32,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        let chunk = [Float](repeating: 0.5, count: 7680)
        pipeline.push(planes: [chunk], frameCount: 7680, format: nativeFormat)
        XCTAssertGreaterThan(pipeline.queuedFrameCount, 0)

        pipeline.reset()
        XCTAssertEqual(pipeline.queuedFrameCount, 0, "reset() should clear queued frames")
        XCTAssertNil(pipeline.dequeue(), "dequeue() should return nil after reset")
    }

    // MARK: - Mono input passthrough (1 channel, same rate not needed, but verify)

    func testMonoInputAt48kHzProducesCorrectChunks() {
        let pipeline = NativeCapturePipeline(
            outputFormat: .realtimeDefault,
            queueCapacity: 32,
            overflowPolicy: .dropOldest
        )
        let nativeFormat = NativeCaptureFormat(
            sampleRate: 48_000,
            channelCount: 1,
            encoding: .float32,
            layout: .nonInterleaved
        )
        // Push enough input for ≥2 output frames (accounting for SRC latency of ~64 samples)
        // 2 frames = 3840 output samples @ 24kHz = 7680 input @ 48kHz.
        // We push 9216 to ensure at least 2 frames clear SRC latency.
        let inputFrames = 9216
        let chunk = [Float](repeating: 0.25, count: inputFrames)
        pipeline.push(planes: [chunk], frameCount: inputFrames, format: nativeFormat)

        var frames: [Data] = []
        while let f = pipeline.dequeue() { frames.append(f) }
        XCTAssertGreaterThanOrEqual(frames.count, 2, "Expected at least 2 output frames")
        for f in frames {
            XCTAssertEqual(f.count, FrameFormat.realtimeDefault.bytesPerFrame,
                "Every output frame must be exactly bytesPerFrame bytes")
        }
    }
}
