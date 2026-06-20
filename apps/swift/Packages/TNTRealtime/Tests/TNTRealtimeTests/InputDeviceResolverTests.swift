import XCTest
@testable import TNTRealtime

/// Tests for the pure capture-device resolution policy (#154).
final class InputDeviceResolverTests: XCTestCase {

    private func dev(_ id: UInt32, _ t: AudioTransport, input: Bool = true) -> ResolvableInput {
        ResolvableInput(id: id, transport: t, hasInputStreams: input)
    }

    func testNonBluetoothDefaultUsedAsIs() {
        // USB/built-in default → use it, even with AirPods also present.
        let usb = dev(1, .other)
        let airpods = dev(2, .bluetooth)
        let id = resolveInputDevice(systemDefault: usb, all: [usb, airpods], useSystemDefault: false)
        XCTAssertEqual(id, 1)
    }

    func testBuiltInDefaultUsedAsIs() {
        let builtIn = dev(1, .builtIn)
        let id = resolveInputDevice(systemDefault: builtIn, all: [builtIn], useSystemDefault: false)
        XCTAssertEqual(id, 1)
    }

    func testClassicBluetoothDefaultFallsBackToBuiltIn() {
        // AirPods default + built-in available → pick built-in (avoid HFP).
        let airpods = dev(2, .bluetooth)
        let builtIn = dev(1, .builtIn)
        let id = resolveInputDevice(systemDefault: airpods, all: [builtIn, airpods], useSystemDefault: false)
        XCTAssertEqual(id, 1, "Classic-BT default must yield to the built-in mic")
    }

    func testBluetoothDefaultFallsBackToOtherNonBTWhenNoBuiltIn() {
        let airpods = dev(2, .bluetooth)
        let usb = dev(3, .other)
        let id = resolveInputDevice(systemDefault: airpods, all: [usb, airpods], useSystemDefault: false)
        XCTAssertEqual(id, 3, "No built-in → any non-classic-BT input")
    }

    func testBluetoothDefaultWithNoSafeAlternativeUsesBluetooth() {
        // Lid closed / AirPods only — accept the BT input (caller logs).
        let airpods = dev(2, .bluetooth)
        let id = resolveInputDevice(systemDefault: airpods, all: [airpods], useSystemDefault: false)
        XCTAssertEqual(id, 2)
    }

    func testEscapeToggleHonorsBluetoothDefault() {
        let airpods = dev(2, .bluetooth)
        let builtIn = dev(1, .builtIn)
        let id = resolveInputDevice(systemDefault: airpods, all: [builtIn, airpods], useSystemDefault: true)
        XCTAssertEqual(id, 2, "Escape toggle on → honor the system default exactly, even Bluetooth")
    }

    func testBluetoothLEDefaultNotAvoided() {
        // LE Audio is not categorically blocked (may not force HFP).
        let le = dev(5, .bluetoothLE)
        let builtIn = dev(1, .builtIn)
        let id = resolveInputDevice(systemDefault: le, all: [builtIn, le], useSystemDefault: false)
        XCTAssertEqual(id, 5, "Bluetooth LE default is used as-is, not bumped to built-in")
    }

    func testBuiltInWithoutInputStreamsSkipped() {
        // A built-in with no input streams (output-only) must not be chosen.
        let airpods = dev(2, .bluetooth)
        let builtInOutputOnly = dev(1, .builtIn, input: false)
        let usb = dev(3, .other)
        let id = resolveInputDevice(systemDefault: airpods, all: [builtInOutputOnly, usb, airpods], useSystemDefault: false)
        XCTAssertEqual(id, 3, "Built-in without input streams is skipped; falls through to USB")
    }

    func testNoDefaultPicksFirstCapableDevice() {
        let outputOnly = dev(9, .other, input: false)
        let mic = dev(3, .other)
        let id = resolveInputDevice(systemDefault: nil, all: [outputOnly, mic], useSystemDefault: false)
        XCTAssertEqual(id, 3)
    }

    func testNoDevicesAtAllReturnsNil() {
        XCTAssertNil(resolveInputDevice(systemDefault: nil, all: [], useSystemDefault: false))
    }
}
