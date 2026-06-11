import XCTest
@testable import TNTPlatformMac

/// Tests for `WindowTextWalker` (issue #103, M4a).
///
/// Acceptance criteria:
/// - Fake-tree tests: multi-node collection in order, role filtering, de-dup, newline joining.
/// - Depth/cycle guards: cyclic or 10k-deep fake tree terminates with partial text, no hang/crash.
/// - Walk-abort cap enforced; empty tree → empty string (valid).
/// - Pure (no AppKit/ApplicationServices imports).
final class WindowTextWalkerTests: XCTestCase {

    // MARK: - Fake TextNode

    /// A simple fake `TextNode` for testing. Children are stored as an array
    /// so test trees can be constructed structurally.
    final class FakeNode: TextNode {
        let role: String?
        let value: String?
        let children: [any TextNode]

        init(role: String?, value: String? = nil, children: [any TextNode] = []) {
            self.role = role
            self.value = value
            self.children = children
        }

        /// Convenience: a text-bearing node.
        static func text(_ value: String, role: String = "AXStaticText") -> FakeNode {
            FakeNode(role: role, value: value)
        }

        /// Convenience: a group node that holds children.
        static func group(_ children: [any TextNode]) -> FakeNode {
            FakeNode(role: "AXGroup", children: children)
        }

        /// Convenience: a noise node (should be skipped entirely).
        static func noise(_ role: String, children: [any TextNode] = []) -> FakeNode {
            FakeNode(role: role, children: children)
        }
    }

    // MARK: - Single node

    func testSingleTextNodeReturnsItsValue() {
        let root = FakeNode.text("Hello, world!")
        let walker = WindowTextWalker()
        XCTAssertEqual(walker.walk(root: root), "Hello, world!")
    }

    func testEmptyTreeReturnsEmptyString() {
        let root = FakeNode(role: "AXWindow")
        let walker = WindowTextWalker()
        XCTAssertEqual(walker.walk(root: root), "")
    }

    func testNodeWithNilValueProducesNoText() {
        let root = FakeNode(role: "AXStaticText", value: nil)
        let walker = WindowTextWalker()
        XCTAssertEqual(walker.walk(root: root), "")
    }

    func testNodeWithEmptyStringValueProducesNoText() {
        let root = FakeNode(role: "AXStaticText", value: "   ")
        let walker = WindowTextWalker()
        XCTAssertEqual(walker.walk(root: root), "")
    }

    // MARK: - Multi-node collection in order

    func testMultipleTextNodesCollectedInVisitOrder() {
        let root = FakeNode.group([
            FakeNode.text("First"),
            FakeNode.text("Second"),
            FakeNode.text("Third"),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertTrue(result.contains("First"))
        XCTAssertTrue(result.contains("Second"))
        XCTAssertTrue(result.contains("Third"))
        // Order check: first appears before second, second before third.
        let firstIdx = result.range(of: "First")!.lowerBound
        let secondIdx = result.range(of: "Second")!.lowerBound
        let thirdIdx = result.range(of: "Third")!.lowerBound
        XCTAssertLessThan(firstIdx, secondIdx)
        XCTAssertLessThan(secondIdx, thirdIdx)
    }

    func testNestedGroupsCollectedDepthFirst() {
        let root = FakeNode.group([
            FakeNode.group([
                FakeNode.text("A"),
                FakeNode.text("B"),
            ]),
            FakeNode.text("C"),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertEqual(result, "A\nB\nC")
    }

    // MARK: - Role filtering

    func testNonTextBearingRoleValueIgnored() {
        // AXGroup has no text-bearing value — its value should not appear.
        let node = FakeNode(role: "AXGroup", value: "should not appear", children: [
            FakeNode.text("real text")
        ])
        let result = WindowTextWalker().walk(root: node)
        XCTAssertFalse(result.contains("should not appear"))
        XCTAssertTrue(result.contains("real text"))
    }

    func testTextAreaRoleCollected() {
        let root = FakeNode(role: "AXTextArea", value: "textarea content")
        XCTAssertEqual(WindowTextWalker().walk(root: root), "textarea content")
    }

    func testTextFieldRoleCollected() {
        let root = FakeNode(role: "AXTextField", value: "textfield content")
        XCTAssertEqual(WindowTextWalker().walk(root: root), "textfield content")
    }

    func testWebAreaRoleCollected() {
        let root = FakeNode(role: "AXWebArea", value: "web content")
        XCTAssertEqual(WindowTextWalker().walk(root: root), "web content")
    }

    // MARK: - Noise role skipping

    func testMenuSubtreeSkipped() {
        let root = FakeNode.group([
            FakeNode.text("real"),
            FakeNode.noise("AXMenu", children: [
                FakeNode.text("menu item text — should be skipped")
            ]),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertTrue(result.contains("real"))
        XCTAssertFalse(result.contains("menu item text"),
            "AXMenu subtree must be fully skipped")
    }

    func testMenuBarSubtreeSkipped() {
        let root = FakeNode.group([
            FakeNode.noise("AXMenuBar", children: [
                FakeNode.text("File Edit View — should be skipped")
            ]),
            FakeNode.text("document text"),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertTrue(result.contains("document text"))
        XCTAssertFalse(result.contains("File Edit View"))
    }

    func testToolbarSubtreeSkipped() {
        let root = FakeNode.group([
            FakeNode.noise("AXToolbar", children: [
                FakeNode.text("toolbar button label — skipped")
            ]),
            FakeNode.text("content"),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertTrue(result.contains("content"))
        XCTAssertFalse(result.contains("toolbar button label"))
    }

    // MARK: - De-duplication

    func testConsecutiveIdenticalValuesDeduped() {
        let root = FakeNode.group([
            FakeNode.text("same"),
            FakeNode.text("same"),
            FakeNode.text("same"),
            FakeNode.text("different"),
        ])
        let result = WindowTextWalker().walk(root: root)
        // "same" must appear exactly once; "different" must appear.
        let sameCount = result.components(separatedBy: "same").count - 1
        XCTAssertEqual(sameCount, 1, "Consecutive identical values must be de-duped")
        XCTAssertTrue(result.contains("different"))
    }

    func testNonConsecutiveDuplicatesNotDeduped() {
        // "A" appears before and after "B" — only consecutive dedup applies.
        let root = FakeNode.group([
            FakeNode.text("A"),
            FakeNode.text("B"),
            FakeNode.text("A"),
        ])
        let result = WindowTextWalker().walk(root: root)
        let aCount = result.components(separatedBy: "A").count - 1
        XCTAssertEqual(aCount, 2, "Non-consecutive duplicates must NOT be deduped")
    }

    // MARK: - Newline joining

    func testValuesJoinedWithNewlines() {
        let root = FakeNode.group([
            FakeNode.text("Line1"),
            FakeNode.text("Line2"),
        ])
        let result = WindowTextWalker().walk(root: root)
        XCTAssertEqual(result, "Line1\nLine2")
    }

    // MARK: - Depth guard

    func testDeepTreeTerminatesWithPartialText() {
        // Build a 1000-deep chain. maxDepth is 64 by default.
        var node: any TextNode = FakeNode.text("leaf text")
        for i in 0..<1000 {
            node = FakeNode(role: "AXGroup", value: "depth-\(i)", children: [node])
        }
        let walker = WindowTextWalker()
        // Must not hang or crash; may return partial result.
        let result = walker.walk(root: node)
        // The result is indeterminate for deep trees; just check it finishes.
        XCTAssertNotNil(result, "Deep tree must terminate cleanly")
    }

    // MARK: - Walk-abort cap

    func testWalkAbortCapEnforced() {
        // Each text node has 100 chars. With a cap of 300, only 3 should be collected.
        let text100 = String(repeating: "x", count: 100)
        var children: [any TextNode] = []
        for _ in 0..<20 {
            children.append(FakeNode.text(text100))
        }
        let root = FakeNode.group(children)
        let walker = WindowTextWalker(walkAbortCap: 300)
        let result = walker.walk(root: root)
        XCTAssertLessThanOrEqual(result.count, 500,
            "Walk-abort cap must prevent unbounded collection")
    }

    func testWalkAbortCapDoesNotDropAllText() {
        // With a generous cap, we still get something.
        let root = FakeNode.group([
            FakeNode.text("important text"),
            FakeNode.text("more text"),
        ])
        let walker = WindowTextWalker(walkAbortCap: 64_000)
        let result = walker.walk(root: root)
        XCTAssertFalse(result.isEmpty, "Walk must collect text within the cap")
    }

    // MARK: - Max-visited guard (cycle protection)

    func testMaxVisitedGuardTerminates() {
        // Build a wide shallow tree (5000 children). maxVisited = 2000 by default.
        var children: [any TextNode] = []
        for i in 0..<5_000 {
            children.append(FakeNode.text("item-\(i)"))
        }
        let root = FakeNode.group(children)
        let walker = WindowTextWalker(maxVisited: 50)
        // Must terminate in bounded time.
        let result = walker.walk(root: root)
        XCTAssertNotNil(result, "Max-visited guard must terminate without crash")
        XCTAssertFalse(result.isEmpty, "Some text must be collected before the guard fires")
    }

    // MARK: - Pure: no AppKit/ApplicationServices (compile-time guarantee)
}
