import XCTest
@testable import TNTRealtime

/// Tests for the SPSC float ring (#141): order preservation, overflow drop +
/// counting, partial read, reset, and interleaved write/read.
final class CaptureFloatRingTests: XCTestCase {

    private func write(_ ring: CaptureFloatRing, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ ring: CaptureFloatRing, max: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max)
        let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, maxCount: $0.count) }
        return Array(out.prefix(n))
    }

    func testWriteThenReadReturnsSameOrder() {
        let ring = CaptureFloatRing(capacity: 16)
        write(ring, [1, 2, 3, 4])
        XCTAssertEqual(read(ring, max: 4), [1, 2, 3, 4])
    }

    func testReadEmptyReturnsZero() {
        let ring = CaptureFloatRing(capacity: 8)
        XCTAssertEqual(read(ring, max: 4), [])
    }

    func testPartialReadLeavesRemainder() {
        let ring = CaptureFloatRing(capacity: 16)
        write(ring, [1, 2, 3, 4, 5])
        XCTAssertEqual(read(ring, max: 2), [1, 2])
        XCTAssertEqual(read(ring, max: 10), [3, 4, 5])
    }

    func testOverflowDropsExcessAndCounts() {
        let ring = CaptureFloatRing(capacity: 4)
        write(ring, [1, 2, 3, 4, 5, 6])   // 2 over capacity
        XCTAssertEqual(ring.droppedSamples, 2)
        XCTAssertEqual(read(ring, max: 10), [1, 2, 3, 4], "First 4 kept, overflow dropped")
    }

    func testWrapAroundPreservesOrder() {
        let ring = CaptureFloatRing(capacity: 4)
        write(ring, [1, 2, 3])
        XCTAssertEqual(read(ring, max: 2), [1, 2])   // head advances to 2
        write(ring, [4, 5])                           // wraps past capacity
        XCTAssertEqual(read(ring, max: 10), [3, 4, 5])
    }

    func testAvailableReflectsPending() {
        let ring = CaptureFloatRing(capacity: 8)
        write(ring, [1, 2, 3])
        XCTAssertEqual(ring.available, 3)
        _ = read(ring, max: 1)
        XCTAssertEqual(ring.available, 2)
    }

    func testResetClearsContentAndDropCounter() {
        let ring = CaptureFloatRing(capacity: 4)
        write(ring, [1, 2, 3, 4, 5])   // drops 1
        XCTAssertEqual(ring.droppedSamples, 1)
        ring.reset()
        XCTAssertEqual(ring.available, 0)
        XCTAssertEqual(ring.droppedSamples, 0)
        XCTAssertEqual(read(ring, max: 4), [])
    }

    func testInterleavedWriteReadSequence() {
        let ring = CaptureFloatRing(capacity: 8)
        var expected: [Float] = []
        var got: [Float] = []
        for cycle in 0..<20 {
            let chunk: [Float] = [Float(cycle) * 3, Float(cycle) * 3 + 1, Float(cycle) * 3 + 2]
            write(ring, chunk)
            expected.append(contentsOf: chunk)
            got.append(contentsOf: read(ring, max: 3))
        }
        // Drain the tail.
        got.append(contentsOf: read(ring, max: 100))
        XCTAssertEqual(got, expected, "SPSC interleave preserves all samples in order (capacity never exceeded here)")
    }
}
