import XCTest
@testable import TNTRealtime

/// Frame-size math for the OpenAI Realtime PCM16 24 kHz mono pipeline.
final class FrameFormatTests: XCTestCase {

    func testRealtimeDefaultMatchesAcceptanceCriteria() {
        // Per M0/S6: PCM16 mono 24 kHz, 80ms frames, 1920 samples / 3840
        // bytes per frame.
        let f = FrameFormat.realtimeDefault
        XCTAssertEqual(f.sampleRate, 24_000)
        XCTAssertEqual(f.channels, 1)
        XCTAssertEqual(f.frameDurationMs, 80)
        XCTAssertEqual(f.samplesPerFrame, 1_920)
        XCTAssertEqual(f.bytesPerFrame, 3_840)
    }

    func testSamplesPerFrameScalesWithDuration() {
        let f = FrameFormat(sampleRate: 24_000, channels: 1, frameDurationMs: 20)
        XCTAssertEqual(f.samplesPerFrame, 480)
        XCTAssertEqual(f.bytesPerFrame, 960)
    }

    func testBytesPerFrameAccountsForChannels() {
        let mono = FrameFormat(sampleRate: 24_000, channels: 1, frameDurationMs: 80)
        let stereo = FrameFormat(sampleRate: 24_000, channels: 2, frameDurationMs: 80)
        XCTAssertEqual(stereo.bytesPerFrame, 2 * mono.bytesPerFrame)
    }

    func testBase64LengthPerFrameIsCeilingDivThreeTimesFour() {
        // OpenAI Realtime expects base64-encoded `input_audio_buffer.append`
        // payloads. Pinning the size gives the WS path a deterministic
        // upper bound on per-frame allocation.
        let f = FrameFormat.realtimeDefault
        // 3840 bytes → ceil(3840 / 3) * 4 = 1280 * 4 = 5120
        XCTAssertEqual(f.base64LengthPerFrame, 5_120)
    }

    func testBase64LengthHandlesOddByteCounts() {
        // Force a non-multiple-of-three byte count by picking a 17ms
        // frame: 24_000 * 17 / 1000 = 408 samples → 816 bytes.
        // ceil(816 / 3) * 4 = 272 * 4 = 1088.
        let f = FrameFormat(sampleRate: 24_000, channels: 1, frameDurationMs: 17)
        XCTAssertEqual(f.bytesPerFrame, 816)
        XCTAssertEqual(f.base64LengthPerFrame, 1_088)
    }
}
