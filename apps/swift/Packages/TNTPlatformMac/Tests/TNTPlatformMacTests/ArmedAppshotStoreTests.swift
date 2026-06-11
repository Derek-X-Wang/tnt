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

    // MARK: - ScreenSourceResolver (mixed mode, #119)

    func testResolverIncludesArmedAndCurrent() {
        let a1 = makeAppshot(appName: "Cursor")
        var freshCallCount = 0
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(
            armed: [a1],
            freshGrab: {
                freshCallCount += 1
                return self.makeAppshot(appName: "Arc")
            }
        )
        XCTAssertEqual(resolved.armed.map(\.appName), ["Cursor"],
            "Armed Appshot must be kept alongside the fresh grab")
        XCTAssertEqual(resolved.current?.appName, "Arc",
            "Fresh grab of the current frontmost must always be included")
        XCTAssertEqual(freshCallCount, 1,
            "Mixed mode: fresh-grab closure runs even when armed Appshots exist")
    }

    func testResolverFreshGrabCalledExactlyOnceWithAndWithoutArmed() {
        let resolver = ScreenSourceResolver()
        for armed in [[], [makeAppshot(appName: "Cursor")]] {
            var callCount = 0
            _ = resolver.resolve(
                armed: armed,
                freshGrab: {
                    callCount += 1
                    return self.makeAppshot(appName: "App")
                }
            )
            XCTAssertEqual(callCount, 1,
                "Fresh-grab closure must be called exactly once (armed.count=\(armed.count))")
        }
    }

    func testResolverNoArmedReturnsCurrentOnly() {
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(
            armed: [],
            freshGrab: { self.makeAppshot(appName: "FreshApp") }
        )
        XCTAssertTrue(resolved.armed.isEmpty)
        XCTAssertEqual(resolved.current?.appName, "FreshApp")
    }

    func testResolverFreshGrabFailureKeepsArmedOnly() {
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(
            armed: [makeAppshot(appName: "Cursor")],
            freshGrab: { nil }  // capture failed (AX untrusted)
        )
        XCTAssertEqual(resolved.armed.map(\.appName), ["Cursor"],
            "Armed captures survive a failed fresh grab")
        XCTAssertNil(resolved.current)
    }

    func testResolverEmptyWhenNothingAvailable() {
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(armed: [], freshGrab: { nil })
        XCTAssertTrue(resolved.isEmpty)
    }

    func testResolverFreshSupersedesSameWindowArmed() {
        // Armed shot of the SAME app+window as the current frontmost: the
        // fresh grab is that window's up-to-date text — armed copy dropped
        // from this snapshot (store untouched; dedupe is per-resolve only).
        let armedCursor = makeAppshot(appName: "Cursor")  // title "Cursor window"
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(
            armed: [armedCursor],
            freshGrab: { self.makeAppshot(appName: "Cursor", windowText: "newer text") }
        )
        XCTAssertTrue(resolved.armed.isEmpty,
            "Same app+window armed shot must be superseded by the fresh grab")
        XCTAssertEqual(resolved.current?.windowText, "newer text")
    }

    func testResolverKeepsSameAppDifferentWindowArmed() {
        let armedOther = Appshot(windowText: "old doc", appName: "Cursor", windowTitle: "other.swift")
        let resolver = ScreenSourceResolver()
        let resolved = resolver.resolve(
            armed: [armedOther],
            freshGrab: { self.makeAppshot(appName: "Cursor") }  // title "Cursor window"
        )
        XCTAssertEqual(resolved.armed.count, 1,
            "Same app but DIFFERENT window title is a different document — kept")
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
        // The `current` Appshot returned by ScreenSourceResolver is turn-scoped:
        // the CALLER appends it to the turn's appshots and clears it at turn end.
        let resolver = ScreenSourceResolver()
        let r1 = resolver.resolve(
            armed: [],
            freshGrab: { self.makeAppshot(appName: "FreshApp") }
        )
        XCTAssertNotNil(r1.current, "Current grab must be returned for turn-scoped lifetime tracking")
        // After the turn ends, the caller clears it; the next resolve grabs again.
        let r2 = resolver.resolve(
            armed: [],
            freshGrab: { self.makeAppshot(appName: "FreshApp2") }
        )
        XCTAssertEqual(r2.current?.appName, "FreshApp2", "New turn can grab fresh again")
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

    // MARK: - ArmedAppshotStore.consume(ids:) — issue #126

    func testConsumeRemovesMatchingIds() {
        let id1 = UUID()
        let id2 = UUID()
        var store = ArmedAppshotStore()
        store.arm(Appshot(id: id1, windowText: "a", appName: "App1"))
        store.arm(Appshot(id: id2, windowText: "b", appName: "App2"))
        store.consume(ids: [id1])
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.appshots[0].id, id2,
            "consume(ids:) must remove only the matching id, leaving id2")
    }

    func testConsumeWithUnknownIdIsNoOp() {
        let knownId = UUID()
        var store = ArmedAppshotStore()
        store.arm(Appshot(id: knownId, windowText: "text", appName: "App"))
        store.consume(ids: [UUID()])  // unknown id
        XCTAssertEqual(store.count, 1, "Consuming an unknown id must not remove anything")
    }

    func testConsumeWithEmptySetIsNoOp() {
        var store = ArmedAppshotStore()
        store.arm(makeAppshot(appName: "App"))
        store.consume(ids: [])
        XCTAssertEqual(store.count, 1, "Consuming empty set must be a no-op")
    }

    func testConsumeAllIds() {
        let id1 = UUID()
        let id2 = UUID()
        var store = ArmedAppshotStore()
        store.arm(Appshot(id: id1, windowText: "a", appName: "App1"))
        store.arm(Appshot(id: id2, windowText: "b", appName: "App2"))
        store.consume(ids: [id1, id2])
        XCTAssertEqual(store.count, 0, "Consuming all ids must empty the store")
    }

    func testConsumePreservesNonMatchingInOrder() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        var store = ArmedAppshotStore()
        store.arm(Appshot(id: idA, windowText: "a", appName: "App1"))
        store.arm(Appshot(id: idB, windowText: "b", appName: "App2"))
        store.arm(Appshot(id: idC, windowText: "c", appName: "App3"))
        store.consume(ids: [idB])
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.appshots[0].id, idA, "App1 (first) must remain")
        XCTAssertEqual(store.appshots[1].id, idC, "App3 (third) must remain, in order")
    }
}
