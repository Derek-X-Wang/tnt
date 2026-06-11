import XCTest
import TNTCore
@testable import TNTPlatformMac

/// Tests for `AccessibilityClient` (issue #49) through its injectable seams:
/// a stub `WindowSignalsReading` and a stub trust gate. The real AX reads
/// (`AXWindowSignalsReader`) are TCC-bound and verified on hardware via the
/// PR's manual-dogfood checklist.
@MainActor
final class AccessibilityClientTests: XCTestCase {

    private final class StubReader: WindowSignalsReading {
        var signals: RawWindowSignals
        private(set) var readCount = 0
        init(_ signals: RawWindowSignals) { self.signals = signals }
        func read() -> RawWindowSignals {
            readCount += 1
            return signals
        }
    }

    func testCaptureNowFeedsSignalsThroughPureAssembly() {
        let reader = StubReader(RawWindowSignals(
            appName: "Cursor",
            windowTitle: "main.swift — tnt",
            selectedText: "  let x = 1  "
        ))
        let client = AccessibilityClient(reader: reader, trustGate: { true })

        let capture = client.captureNow()

        XCTAssertEqual(capture, assembleCaptureSet(from: reader.signals))
        XCTAssertEqual(capture.appName, "Cursor")
        // Assembly trims whitespace-padded selections.
        XCTAssertEqual(capture.selectedText, "let x = 1")
        XCTAssertEqual(reader.readCount, 1)
    }

    func testCaptureNowWithAllNilSignalsDegradesToEmpty() {
        let reader = StubReader(RawWindowSignals())
        let client = AccessibilityClient(reader: reader, trustGate: { true })

        let capture = client.captureNow()

        XCTAssertTrue(capture.isEmpty)
    }

    func testCaptureNowUntrustedReturnsEmptyWithoutReading() {
        let reader = StubReader(RawWindowSignals(appName: "Cursor"))
        let client = AccessibilityClient(reader: reader, trustGate: { false })

        let capture = client.captureNow()

        XCTAssertTrue(capture.isEmpty)
        // Privacy guard: when Accessibility is not trusted, no AX reads happen.
        XCTAssertEqual(reader.readCount, 0)
    }

    func testCaptureNowReChecksTrustEachCall() {
        var trusted = false
        let reader = StubReader(RawWindowSignals(appName: "Cursor", windowTitle: "t — tnt"))
        let client = AccessibilityClient(reader: reader, trustGate: { trusted })

        XCTAssertTrue(client.captureNow().isEmpty)
        trusted = true
        // JIT grant mid-session takes effect on the next capture, no restart.
        XCTAssertEqual(client.captureNow().appName, "Cursor")
    }
}
