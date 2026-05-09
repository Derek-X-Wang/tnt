import XCTest
@testable import TNTRealtime

/// Pure dB-from-frame math used by the menu-bar VU indicator.
final class AudioLevelTests: XCTestCase {

    func testSilentFrameClampsToFloor() {
        let silence = Data(count: FrameFormat.realtimeDefault.bytesPerFrame)
        let db = AudioLevel.peakDB(from: silence)
        XCTAssertEqual(db, AudioLevel.floorDB,
                       "Silent input must clamp to the floor (-60 dB) instead of returning -inf.")
    }

    func testFullScaleSampleRegistersAtZeroDB() {
        // Write one sample at INT16_MAX → peak amplitude = 1.0 → 0 dB.
        var data = Data(count: 4)
        let maxLE = UInt16(bitPattern: Int16.max).littleEndian
        data[0] = UInt8(maxLE & 0xff)
        data[1] = UInt8((maxLE >> 8) & 0xff)
        let db = AudioLevel.peakDB(from: data)
        XCTAssertEqual(db, 0.0, accuracy: 0.05)
    }

    func testHalfFullScaleIsAroundMinusSixDB() {
        // 0.5 amplitude ≈ 20*log10(0.5) ≈ -6.02 dB.
        let half = Int16(Int(Int16.max) / 2)
        var data = Data(count: 2)
        let le = UInt16(bitPattern: half).littleEndian
        data[0] = UInt8(le & 0xff)
        data[1] = UInt8((le >> 8) & 0xff)
        let db = AudioLevel.peakDB(from: data)
        XCTAssertEqual(db, -6.0, accuracy: 0.2)
    }
}
