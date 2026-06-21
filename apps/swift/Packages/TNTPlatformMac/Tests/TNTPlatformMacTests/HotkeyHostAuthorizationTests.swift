import XCTest
@testable import TNTPlatformMac

/// Authorization-resolution tests for HotkeyHost (#138).
///
/// The bug: after the Screen-Recording-grant relaunch, the per-process TCC
/// cache freezes `CGRequestListenEventAccess()` on a stale `false` even though
/// Input Monitoring is granted in the live TCC db, so the old `start()` bailed
/// before ever creating the tap. The fix makes `tapCreate` (live-TCC, uncached)
/// the source of truth, with a bounded re-probe ladder. These tests drive that
/// logic through injected seams — no live event tap / run loop / TCC.
@MainActor
final class HotkeyHostAuthorizationTests: XCTestCase {

    private let chord = HotkeyChord(modifiers: [.control, .option], key: .space)

    /// Run all scheduled retries synchronously so the bounded ladder completes
    /// within the test (no real delays).
    private let syncScheduler: (TimeInterval, @escaping () -> Void) -> Void = { _, work in work() }

    private func makeHost(
        requestAccess: Bool,
        installResults: [Bool],
        events: @escaping (HotkeyHost.Event) -> Void
    ) -> (HotkeyHost, () -> Int) {
        var idx = 0
        let install: () -> Bool = {
            defer { idx += 1 }
            return idx < installResults.count ? installResults[idx] : installResults.last ?? false
        }
        let host = HotkeyHost(
            chord: chord,
            requestListenAccess: { requestAccess },
            installTap: install,
            retryScheduler: syncScheduler,
            listener: events
        )
        return (host, { idx })
    }

    /// THE #138 REGRESSION: a stale-false request result must NOT prevent the
    /// tap from installing — a successful tapCreate means authorized.
    func testStaleFalseRequestStillGrantsWhenTapInstalls() {
        var seen: [HotkeyHost.Event] = []
        let (host, _) = makeHost(requestAccess: false, installResults: [true]) { seen.append($0) }
        host.start()
        XCTAssertEqual(host.authorization, .granted)
        XCTAssertEqual(seen, [.permissionChanged(.granted)])
    }

    func testGrantedRequestAndSuccessfulInstallGrants() {
        var seen: [HotkeyHost.Event] = []
        let (host, _) = makeHost(requestAccess: true, installResults: [true]) { seen.append($0) }
        host.start()
        XCTAssertEqual(host.authorization, .granted)
        XCTAssertEqual(seen, [.permissionChanged(.granted)])
    }

    /// The race window: first tapCreate is nil, a re-probe succeeds → granted.
    func testRetryRecoversWhenLiveTCCSettles() {
        var seen: [HotkeyHost.Event] = []
        let (host, attempts) = makeHost(requestAccess: false, installResults: [false, true]) { seen.append($0) }
        host.start()
        XCTAssertEqual(host.authorization, .granted)
        XCTAssertEqual(seen, [.permissionChanged(.granted)])
        XCTAssertEqual(attempts(), 2, "second tapCreate probe should have run and succeeded")
    }

    /// Genuinely ungranted Input Monitoring: tapCreate never succeeds, so after
    /// exhausting the bounded ladder we report denied exactly once.
    func testDeniedAfterExhaustingRetries() {
        var seen: [HotkeyHost.Event] = []
        let (host, attempts) = makeHost(requestAccess: false, installResults: [false]) { seen.append($0) }
        host.start()
        XCTAssertEqual(host.authorization, .denied)
        XCTAssertEqual(seen, [.permissionChanged(.denied)])
        // immediate attempt + two bounded retries (tapRetryDelays.count == 2).
        XCTAssertEqual(attempts(), 3, "should probe tapCreate immediate + 2 retries before denying")
    }
}
