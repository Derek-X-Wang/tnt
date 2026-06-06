import XCTest
@testable import TNTPlatformMac

/// Unit tests for `PromptDeliverer` (issue #83).
///
/// Acceptance criteria:
/// - deliver(_ rewrite:) writes the rewrite to the injected pasteboard sink exactly once.
/// - Never reads the pasteboard — a test with a fake sink asserts read-count == 0.
/// - Chime and notification sinks each fire exactly once per deliver.
/// - Real OS sink impls provided (NSPasteboard write / NSSound / UNUserNotificationCenter).
/// - Unit tests with fake sinks; swift test green.
final class PromptDelivererTests: XCTestCase {

    // MARK: - Fake sinks for testing

    /// Counts write and read calls to verify exactly-once write, zero reads.
    final class FakePasteboardSink: PasteboardSink {
        private(set) var writeCount = 0
        private(set) var readCount = 0
        private(set) var lastWrittenString: String?

        func write(_ string: String) {
            writeCount += 1
            lastWrittenString = string
        }

        func read() -> String? {
            readCount += 1
            return nil
        }
    }

    final class FakeChimeSink: ChimeSink {
        private(set) var playCount = 0
        func play() {
            playCount += 1
        }
    }

    final class FakeNotificationSink: NotificationSink {
        private(set) var fireCount = 0
        private(set) var lastMessage: String?
        func fire(message: String) {
            fireCount += 1
            lastMessage = message
        }
    }

    // MARK: - Helper

    private func makeDeliverer() -> (PromptDeliverer, FakePasteboardSink, FakeChimeSink, FakeNotificationSink) {
        let pasteboard = FakePasteboardSink()
        let chime = FakeChimeSink()
        let notification = FakeNotificationSink()
        let deliverer = PromptDeliverer(
            pasteboard: pasteboard,
            chime: chime,
            notification: notification
        )
        return (deliverer, pasteboard, chime, notification)
    }

    // MARK: - Exactly-once write

    func testDeliverWritesToPasteboardExactlyOnce() {
        let (deliverer, pasteboard, _, _) = makeDeliverer()
        deliverer.deliver("Add a unit test.")
        XCTAssertEqual(pasteboard.writeCount, 1,
            "deliver must write to the pasteboard exactly once")
    }

    func testDeliverWritesCorrectStringToPasteboard() {
        let (deliverer, pasteboard, _, _) = makeDeliverer()
        deliverer.deliver("Add rate-limit unit tests.")
        XCTAssertEqual(pasteboard.lastWrittenString, "Add rate-limit unit tests.",
            "deliver must write the exact rewrite string to the pasteboard")
    }

    func testMultipleDeliversWriteMultipleTimes() {
        let (deliverer, pasteboard, _, _) = makeDeliverer()
        deliverer.deliver("First.")
        deliverer.deliver("Second.")
        XCTAssertEqual(pasteboard.writeCount, 2,
            "Each deliver call must write once — 2 calls = 2 writes")
        XCTAssertEqual(pasteboard.lastWrittenString, "Second.")
    }

    // MARK: - Never reads the pasteboard

    func testDeliverNeverReadsThePasteboard() {
        let (deliverer, pasteboard, _, _) = makeDeliverer()
        deliverer.deliver("Deliver me.")
        XCTAssertEqual(pasteboard.readCount, 0,
            "PromptDeliverer must never read from the pasteboard (ADR-0004)")
    }

    func testReadCountIsZeroEvenBeforeDeliver() {
        let (_, pasteboard, _, _) = makeDeliverer()
        XCTAssertEqual(pasteboard.readCount, 0,
            "PromptDeliverer must not read the pasteboard at init time either")
    }

    // MARK: - Chime fires exactly once per deliver

    func testChimeFiresExactlyOncePerDeliver() {
        let (deliverer, _, chime, _) = makeDeliverer()
        deliverer.deliver("Prompt text.")
        XCTAssertEqual(chime.playCount, 1,
            "Chime must play exactly once per deliver call")
    }

    func testChimeFiresOncePerCallForMultipleDelivers() {
        let (deliverer, _, chime, _) = makeDeliverer()
        deliverer.deliver("First.")
        deliverer.deliver("Second.")
        XCTAssertEqual(chime.playCount, 2,
            "Chime must play once for each deliver call")
    }

    // MARK: - Notification fires exactly once per deliver

    func testNotificationFiresExactlyOncePerDeliver() {
        let (deliverer, _, _, notification) = makeDeliverer()
        deliverer.deliver("Prompt text.")
        XCTAssertEqual(notification.fireCount, 1,
            "Notification must fire exactly once per deliver call")
    }

    func testNotificationFiresWithNonEmptyMessage() {
        let (deliverer, _, _, notification) = makeDeliverer()
        deliverer.deliver("Some rewrite content.")
        XCTAssertFalse(notification.lastMessage?.isEmpty ?? true,
            "Notification message must be non-empty")
    }

    func testNotificationFiresOncePerCallForMultipleDelivers() {
        let (deliverer, _, _, notification) = makeDeliverer()
        deliverer.deliver("First.")
        deliverer.deliver("Second.")
        XCTAssertEqual(notification.fireCount, 2,
            "Notification must fire once for each deliver call")
    }

    // MARK: - All three sinks fire together

    func testAllSinksFireOnDeliver() {
        let (deliverer, pasteboard, chime, notification) = makeDeliverer()
        deliverer.deliver("All together now.")
        XCTAssertEqual(pasteboard.writeCount, 1)
        XCTAssertEqual(chime.playCount, 1)
        XCTAssertEqual(notification.fireCount, 1)
    }
}
