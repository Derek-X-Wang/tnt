import XCTest
@testable import TNTRealtime

/// Behavioural contract for `AudioCapture`. The real
/// `VoiceProcessingIOAudioCapture` is hardware-dependent (no usable mic
/// on CI runners), so contract tests run against a `StubAudioCapture`
/// that ships alongside the protocol. The real implementation follows
/// the same idempotency rules — drift here surfaces in the audible
/// failure mode (lamp stays on after release) rather than in the test
/// suite.
final class AudioCaptureContractTests: XCTestCase {

    func testDoubleStartIsGraceful() async throws {
        let stub = StubAudioCapture()
        try await stub.start()
        try await stub.start()
        XCTAssertTrue(stub.isRunning)
        await stub.stop()
        XCTAssertFalse(stub.isRunning)
    }

    func testDoubleStopIsGraceful() async throws {
        let stub = StubAudioCapture()
        try await stub.start()
        await stub.stop()
        await stub.stop()
        XCTAssertFalse(stub.isRunning)
    }

    func testStartStopCyclesDoNotLeakRunningState() async throws {
        let stub = StubAudioCapture()
        for _ in 0..<10 {
            try await stub.start()
            await stub.stop()
        }
        XCTAssertFalse(stub.isRunning)
    }

    func testFramesStreamReceivesEmittedData() async throws {
        let stub = StubAudioCapture()
        try await stub.start()
        let payload = Data(count: FrameFormat.realtimeDefault.bytesPerFrame)
        stub.emit(payload)
        var iterator = stub.frames.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received?.count, payload.count)
        await stub.stop()
    }
}
