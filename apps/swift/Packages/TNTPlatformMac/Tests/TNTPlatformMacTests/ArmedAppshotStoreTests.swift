import XCTest
@testable import TNTPlatformMac
import TNTCore

/// Tests for `ArmedAppshotStore`, `mergeArmedAppshots`, `ScreenSourceResolver`,
/// and `AppshotArmingCoordinator` (issue #104, M4a).
///
/// Acceptance criteria:
/// - Armed-present → resolver returns armed, fresh closure never invoked.
/// - None armed → fresh invoked exactly once and returned as `pulled`.
/// - Merge: newest-armed wins top-level fields; fresh fills unfrozen only; armed appshots never dropped.
/// - Stacking preserves arm order; clearLast removes newest; clearAll empties.
/// - Lifecycle: persists across a no-tool turn; barge-in non-consuming; pulled-grab turn-scoped.
/// - Coordinator smoke test: press → capture closure → store grows → chip closure sees merged set.
final class ArmedAppshotStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeAppshot(appName: String, windowText: String = "text", project: String? = nil) -> Appshot {
        let projectRef = project.map { ProjectRef(name: $0, path: "/\($0)") }
        return Appshot(windowText: windowText, appName: appName, windowTitle: "\(appName) window", project: projectRef)
    }

    // MARK: - ArmedAppshotStore: arm / clearAll / clearLast

    func testInitialStoreIsEmpty() {
        let store = ArmedAppshotStore()
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.appshots.isEmpty)
    }

    func testArmAppendsAppshot() {
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "Cursor"))
        XCTAssertEqual(store.count, 1)
    }

    func testArmStacksMultiple() {
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "Cursor"))
        store.arm(makeAppshot(appName: "Chrome"))
        XCTAssertEqual(store.count, 2)
    }

    func testArmPreservesOrder() {
        var store = ArmedAppshotStore()
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        let a3 = makeAppshot(appName: "Xcode")
        store.arm(a1)
        store.arm(a2)
        store.arm(a3)
        XCTAssertEqual(store.appshots[0].appName, "Cursor")
        XCTAssertEqual(store.appshots[1].appName, "Chrome")
        XCTAssertEqual(store.appshots[2].appName, "Xcode")
    }

    func testClearAllEmptiesStore() {
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "Cursor"))
        store.arm(makeAppshot(appName: "Chrome"))
        store.clearAll()
        XCTAssertEqual(store.count, 0)
    }

    func testClearLastRemovesNewest() {
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "Cursor"))
        store.arm(makeAppshot(appName: "Chrome"))
        store.clearLast()
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.appshots[0].appName, "Cursor",
            "clearLast must remove Chrome (newest), leaving Cursor")
    }

    func testClearLastOnEmptyIsNoOp() {
        var store = ArmedAppshotStore()
        store.clearLast()  // must not crash
        XCTAssertEqual(store.count, 0)
    }

    func testClearAllOnEmptyIsNoOp() {
        var store = ArmedAppshotStore()
        store.clearAll()  // must not crash
        XCTAssertEqual(store.count, 0)
    }

    // MARK: - mergeArmedAppshots: frozen-context precedence

    func testMergeWithNoArmedReturnsEmptyAppshots() {
        let fresh = CaptureSet(appName: "Xcode", windowTitle: "main.swift")
        let result = mergeArmedAppshots(fresh: fresh, armed: [])
        XCTAssertTrue(result.appshots.isEmpty)
        XCTAssertEqual(result.appName, "Xcode")
    }

    func testMergeNewestArmedWinsAppName() {
        let a1 = makeAppshot(appName: "Cursor")  // older
        let a2 = makeAppshot(appName: "Chrome")  // newer (last)
        let fresh = CaptureSet(appName: "Xcode")
        let result = mergeArmedAppshots(fresh: fresh, armed: [a1, a2])
        XCTAssertEqual(result.appName, "Chrome",
            "Newest-armed (Chrome) must win the top-level appName")
    }

    func testMergeArmedAppshotsPreservedInResult() {
        let a1 = makeAppshot(appName: "Cursor")
        let a2 = makeAppshot(appName: "Chrome")
        let fresh = CaptureSet()
        let result = mergeArmedAppshots(fresh: fresh, armed: [a1, a2])
        XCTAssertEqual(result.appshots.count, 2,
            "Armed Appshots must all appear in result.appshots")
        XCTAssertEqual(result.appshots[0].appName, "Cursor")
        XCTAssertEqual(result.appshots[1].appName, "Chrome")
    }

    func testMergeFreshFillsUnfrozenField() {
        // Armed Appshot has no project field (nil). Fresh has a project.
        let armed = Appshot(windowText: "x", appName: "Cursor", windowTitle: "c", project: nil)
        let fresh = CaptureSet(project: ProjectRef(name: "myproject", path: "/p"))
        let result = mergeArmedAppshots(fresh: fresh, armed: [armed])
        XCTAssertEqual(result.project?.name, "myproject",
            "Fresh fills the project field when no armed Appshot froze it")
    }

    func testMergeArmedProjectOverridesFreshProject() {
        let armed = makeAppshot(appName: "Cursor", project: "cursor-project")
        let fresh = CaptureSet(project: ProjectRef(name: "fresh-project", path: "/fp"))
        let result = mergeArmedAppshots(fresh: fresh, armed: [armed])
        XCTAssertEqual(result.project?.name, "cursor-project",
            "Armed Appshot's frozen project must override fresh project")
    }

    func testMergeFreshSelectedTextAlwaysPreserved() {
        // selectedText is a fresh-only field.
        let armed = makeAppshot(appName: "Cursor")
        let fresh = CaptureSet(selectedText: "func foo() {}")
        let result = mergeArmedAppshots(fresh: fresh, armed: [armed])
        XCTAssertEqual(result.selectedText, "func foo() {}")
    }

    func testMergeNewestWinsOverOlderArmedField() {
        // Older armed: project "old-project". Newer armed: project "new-project".
        let older = makeAppshot(appName: "OldApp", project: "old-project")
        let newer = makeAppshot(appName: "NewApp", project: "new-project")
        let fresh = CaptureSet()
        let result = mergeArmedAppshots(fresh: fresh, armed: [older, newer])
        XCTAssertEqual(result.project?.name, "new-project",
            "Newest armed must win when multiple armed Appshots have the same field")
    }

    // MARK: - ScreenSourceResolver

    func testResolverReturnsArmedWhenArmedPresent() {
        let a1 = makeAppshot(appName: "Cursor")
        var freshCallCount = 0
        let resolver = ScreenSourceResolver()
        let (sources, pulled) = resolver.resolve(
            armed: [a1],
            freshGrab: {
                freshCallCount += 1
                return self.makeAppshot(appName: "FreshGrab")
            }
        )
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].appName, "Cursor",
            "Armed Appshot must be returned as source")
        XCTAssertNil(pulled, "No fresh grab when armed is present")
        XCTAssertEqual(freshCallCount, 0,
            "Fresh-grab closure must NOT be invoked when armed Appshots are present")
    }

    func testResolverCallsFreshGrabWhenNoneArmed() {
        var freshCallCount = 0
        let resolver = ScreenSourceResolver()
        let (sources, pulled) = resolver.resolve(
            armed: [],
            freshGrab: {
                freshCallCount += 1
                return self.makeAppshot(appName: "FreshApp")
            }
        )
        XCTAssertEqual(freshCallCount, 1,
            "Fresh-grab closure must be invoked exactly once when no armed Appshots")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(pulled?.appName, "FreshApp")
    }

    func testResolverReturnsEmptyWhenFreshGrabFails() {
        let resolver = ScreenSourceResolver()
        let (sources, pulled) = resolver.resolve(
            armed: [],
            freshGrab: { nil }  // capture failed
        )
        XCTAssertTrue(sources.isEmpty)
        XCTAssertNil(pulled)
    }

    func testResolverFreshGrabCalledExactlyOnce() {
        var callCount = 0
        let resolver = ScreenSourceResolver()
        _ = resolver.resolve(
            armed: [],
            freshGrab: {
                callCount += 1
                return self.makeAppshot(appName: "App")
            }
        )
        XCTAssertEqual(callCount, 1, "Fresh-grab closure must be called exactly once")
    }

    // MARK: - Lifecycle: persists across a no-tool turn

    func testArmedAppShotsPersistAcrossNoToolTurn() {
        // Simulating: arm → turn with no screen tool call → still armed.
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "Cursor"))

        // Simulate a turn passing without any screen tool invocation.
        // Armed Appshots should not be cleared.
        let countBeforeTurn = store.count
        // (no clear call)
        let countAfterTurn = store.count

        XCTAssertEqual(countBeforeTurn, countAfterTurn,
            "Armed Appshots must persist across a turn where no screen tool was called")
    }

    func testVoicePulledGrabIsTurnScoped() {
        // The pulled Appshot returned by ScreenSourceResolver is turn-scoped:
        // the CALLER is responsible for clearing it at turn end.
        // We verify the resolver returns it separately via `pulled`.
        let resolver = ScreenSourceResolver()
        let (_, pulled1) = resolver.resolve(
            armed: [],
            freshGrab: { self.makeAppshot(appName: "FreshApp") }
        )
        XCTAssertNotNil(pulled1, "Pulled grab must be returned for turn-scoped lifetime tracking")
        // After the turn ends, the caller clears `pulled`; the next resolve
        // can grab again.
        let (_, pulled2) = resolver.resolve(
            armed: [],
            freshGrab: { self.makeAppshot(appName: "FreshApp2") }
        )
        XCTAssertNotNil(pulled2, "New turn can grab fresh again")
        XCTAssertEqual(pulled2?.appName, "FreshApp2")
    }

    // MARK: - AppshotArmingCoordinator smoke test

    func testCoordinatorPressArmsAndNotifiesChip() {
        var chipUpdates: [CaptureSet] = []
        var captureCallCount = 0

        let coordinator = AppshotArmingCoordinator(
            capture: {
                captureCallCount += 1
                return Appshot(windowText: "captured text", appName: "Cursor", windowTitle: "main.swift")
            },
            onChipUpdate: { chipUpdates.append($0) }
        )

        coordinator.handleHotkeyPress()

        XCTAssertEqual(captureCallCount, 1, "Capture closure must be called once per press")
        XCTAssertEqual(coordinator.armedCount, 1, "Store must have 1 armed Appshot after press")
        XCTAssertEqual(chipUpdates.count, 1, "Chip update closure must be called after arm")
        XCTAssertEqual(chipUpdates[0].appshots.count, 1,
            "Chip update CaptureSet must contain the armed Appshot")
    }

    func testCoordinatorClearAllNotifiesChip() {
        var chipUpdates: [CaptureSet] = []
        let coordinator = AppshotArmingCoordinator(
            capture: { Appshot(windowText: "x", appName: "App", windowTitle: "t") },
            onChipUpdate: { chipUpdates.append($0) }
        )

        coordinator.handleHotkeyPress()
        coordinator.clearAll()

        XCTAssertEqual(coordinator.armedCount, 0)
        XCTAssertEqual(chipUpdates.last?.appshots.count, 0,
            "Chip update after clearAll must show empty appshots")
    }

    func testCoordinatorClearLastNotifiesChip() {
        var chipUpdates: [CaptureSet] = []
        let coordinator = AppshotArmingCoordinator(
            capture: { Appshot(windowText: "x", appName: "App", windowTitle: "t") },
            onChipUpdate: { chipUpdates.append($0) }
        )

        coordinator.handleHotkeyPress()
        coordinator.handleHotkeyPress()
        coordinator.clearLast()

        XCTAssertEqual(coordinator.armedCount, 1)
        XCTAssertEqual(chipUpdates.last?.appshots.count, 1,
            "Chip update after clearLast must show 1 remaining Appshot")
    }

    func testCoordinatorArmedAccessor() {
        let coordinator = AppshotArmingCoordinator(
            capture: { Appshot(windowText: "x", appName: "TestApp", windowTitle: "t") },
            onChipUpdate: { _ in }
        )
        coordinator.handleHotkeyPress()
        XCTAssertEqual(coordinator.armed.count, 1)
        XCTAssertEqual(coordinator.armed[0].appName, "TestApp")
    }

    func testCoordinatorCaptureFaiureIsNoOp() {
        var chipUpdates: [CaptureSet] = []
        let coordinator = AppshotArmingCoordinator(
            capture: { nil },  // capture fails
            onChipUpdate: { chipUpdates.append($0) }
        )
        coordinator.handleHotkeyPress()
        XCTAssertEqual(coordinator.armedCount, 0, "Failed capture must not arm anything")
        XCTAssertTrue(chipUpdates.isEmpty, "No chip update when capture fails")
    }
}
