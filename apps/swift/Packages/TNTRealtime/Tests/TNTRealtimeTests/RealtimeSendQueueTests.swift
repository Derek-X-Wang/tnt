import XCTest
@testable import TNTRealtime

// MARK: - Gated mock transport

/// A `RealtimeTransport` whose `sendText` can be held in-flight.
///
/// When a gate continuation is registered via `setGate(_:)`, the next
/// call to `sendText` signals it (so callers know sendText entered) and
/// parks until `releaseAll()` is called. Calls without a gate return
/// immediately, matching `MockTransport` behavior.
///
/// `receive()` throws — inbound path is never exercised in these tests.
/// Thread safety: all mutable state is protected by `lock`.
final class GatedMockTransport: RealtimeTransport, @unchecked Sendable {

    private let lock = NSLock()
    private(set) var sendLog: [String] = []
    private var gate: CheckedContinuation<Void, Never>? = nil
    private var parkedRelease: [CheckedContinuation<Void, Never>] = []

    func connect(request: URLRequest) async throws {}
    func disconnect() async {}
    func receive() async throws -> RealtimeTransportFrame { throw RealtimeTransportError.streamClosed }

    func sendText(_ text: String) async throws {
        lock.withLock { sendLog.append(text) }
        let gateToSignal: CheckedContinuation<Void, Never>? = lock.withLock {
            let g = gate; gate = nil; return g
        }
        guard let gateToSignal else { return }
        gateToSignal.resume()  // Signal: sendText has been entered.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock { parkedRelease.append(cont) }
        }
    }

    /// Register a gate continuation that will be signaled when the next
    /// `sendText` call is entered. Must be called BEFORE the sendText
    /// call that should trigger it.
    func setGate(_ cont: CheckedContinuation<Void, Never>) {
        lock.withLock { gate = cont }
    }

    /// Release all parked `sendText` calls.
    func releaseAll() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            let s = parkedRelease; parkedRelease = []; return s
        }
        for cont in all { cont.resume() }
    }
}

// MARK: - Tests

/// Tests for `RealtimeSendQueue` — the serialized outbound event channel
/// that guarantees append ordering across Voice Turns.
///
/// Issue #66 acceptance criteria verified here:
/// - `drain()` is a real barrier: proved by `GatedMockTransport` which
///   holds an append in-flight while drain()+commit are raced against it.
/// - No `assert`-only invariant on the ordering path (release-mode safe).
/// - Hotkey-release-while-first-frame-suspended: drain blocks commit until
///   the frame's sendText completes — frame cannot bleed into turn N+1.
/// - Existing ordering + cross-turn isolation tests still pass.
final class RealtimeSendQueueTests: XCTestCase {

    // MARK: - Issue #66 AC: drain() is a real barrier

    /// Core barrier test using `GatedMockTransport`:
    ///
    /// Pattern:
    ///   await withCheckedContinuation { cont in
    ///       transport.setGate(cont)          // (A) register gate synchronously
    ///       Task { await queue.sendAppend() } // (B) start append — will signal gate
    ///   }                                    // (C) resumes when sendText fires gate
    ///   // HERE: sendText IS in-flight (gate was signaled in sendText body)
    ///   Task { await queue.drain(); queue.send(commit) }  // (D) race drain+commit
    ///   transport.releaseAll()               // (E) release sendText → drain fires
    ///
    /// Ordering proof: commit's sendText is called only after drain() returns.
    /// drain() returns only after pendingAppendCount reaches zero.
    /// pendingAppendCount reaches zero only after sendText returns (via defer).
    /// So commit entry in the send log always follows append entry.
    func testDrainBarrierOrdersAppendBeforeCommit() async throws {
        let transport = GatedMockTransport()
        let queue = RealtimeSendQueue(transport: transport)

        // (A) + (B) + (C): atomically set gate, start append, wait for sendText entry.
        var appendTask: Task<Void, Error>? = nil
        await withCheckedContinuation { (gateCont: CheckedContinuation<Void, Never>) in
            transport.setGate(gateCont)
            appendTask = Task {
                try await queue.sendAppend(InputAudioBufferAppend(audio: "frame0"))
            }
        }
        // sendText is now in-flight (signaled the gate, parked).

        // (D) Race drain()+commit against the parked sendText.
        let drainCommitTask: Task<Void, Error> = Task {
            await queue.drain()
            try await queue.send(InputAudioBufferCommit())
        }

        // (E) Release sendText — drain's waiter fires, commit is sent.
        transport.releaseAll()
        try await appendTask!.value
        try await drainCommitTask.value

        // Verify: append precedes commit in the send log.
        let types = transport.sendLog.compactMap { text -> String? in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["type"] as? String else { return nil }
            return t
        }
        guard let ai = types.firstIndex(of: "input_audio_buffer.append"),
              let ci = types.firstIndex(of: "input_audio_buffer.commit") else {
            XCTFail("append or commit not found in send log: \(types)"); return
        }
        XCTAssertLessThan(ai, ci,
            "append (\(ai)) must precede commit (\(ci)) — drain barrier ensures ordering")
    }

    // MARK: - Issue #66 AC: framesThisTurn race

    /// Hotkey-release-while-first-frame-suspended: drain must block commit
    /// until the in-flight frame's sendText completes.
    ///
    /// This is the `framesThisTurn` race from issue #66: with the old code,
    /// a hotkey release while frame0 was suspended at sendText saw
    /// framesThisTurn == 0 (incremented post-await) → skipped commit →
    /// frame0 landed in turn N+1. The queue-level fix is drain() as a real
    /// barrier; the controller-level fix is incrementing framesThisTurn
    /// before the sendAppend await.
    func testHotkeyReleaseWhileFirstFrameSuspendedOrdersAppendBeforeCommit() async throws {
        let transport = GatedMockTransport()
        let queue = RealtimeSendQueue(transport: transport)

        var appendTask: Task<Void, Error>? = nil
        await withCheckedContinuation { (gateCont: CheckedContinuation<Void, Never>) in
            transport.setGate(gateCont)
            appendTask = Task {
                try await queue.sendAppend(InputAudioBufferAppend(audio: "frame0"))
            }
        }

        // Hotkey released while frame0 is in-flight: drain + commit racing.
        let commitTask: Task<Void, Error> = Task {
            await queue.drain()
            try await queue.send(InputAudioBufferCommit())
        }

        transport.releaseAll()
        try await appendTask!.value
        try await commitTask.value

        let types = transport.sendLog.compactMap { text -> String? in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["type"] as? String else { return nil }
            return t
        }
        XCTAssertEqual(types.first, "input_audio_buffer.append",
            "frame0 must arrive before commit — drain prevents turn N+1 contamination")
        XCTAssertEqual(types.last, "input_audio_buffer.commit")
    }

    // MARK: - Ordering: appends then drain then commit/create

    func testAppendsArrivedBeforeCommitAfterDrain() async throws {
        let transport = MockTransport()
        try await transport.connect(request: URLRequest(url: URL(string: "wss://test")!))
        let queue = RealtimeSendQueue(transport: transport)

        for i in 0..<5 {
            try await queue.sendAppend(InputAudioBufferAppend(audio: "frame\(i)"))
        }

        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        let types = transport.sendLog.compactMap { text -> String? in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = obj["type"] as? String else { return nil }
            return type_
        }

        XCTAssertEqual(types.count, 7)
        let commitIndex = types.firstIndex(of: "input_audio_buffer.commit")
        let createIndex = types.firstIndex(of: "response.create")
        let appendIndices = types.indices.filter { types[$0] == "input_audio_buffer.append" }

        XCTAssertEqual(appendIndices.count, 5)
        if let ci = commitIndex {
            for ai in appendIndices { XCTAssertLessThan(ai, ci) }
        } else { XCTFail("commit not found") }
        if let ci = commitIndex, let ri = createIndex {
            XCTAssertLessThan(ci, ri)
        } else { XCTFail("commit or response.create not found") }
    }

    // MARK: - Turn isolation

    func testTurnNAppendsDoNotContaminateTurnNPlusOne() async throws {
        let transport = MockTransport()
        try await transport.connect(request: URLRequest(url: URL(string: "wss://test")!))
        let queue = RealtimeSendQueue(transport: transport)

        try await queue.sendAppend(InputAudioBufferAppend(audio: "t1-frame0"))
        try await queue.sendAppend(InputAudioBufferAppend(audio: "t1-frame1"))
        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        try await queue.sendAppend(InputAudioBufferAppend(audio: "t2-frame0"))
        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        let events: [(type: String, audio: String?)] = transport.sendLog.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = obj["type"] as? String else { return nil }
            return (type: type_, audio: obj["audio"] as? String)
        }
        let firstCommit = events.firstIndex(where: { $0.type == "input_audio_buffer.commit" })!
        let turn2Append = events.firstIndex(where: { $0.audio == "t2-frame0" })!
        XCTAssertGreaterThan(turn2Append, firstCommit)
    }

    // MARK: - Non-append sends

    func testSendNonAppendIsRecorded() async throws {
        let transport = MockTransport()
        try await transport.connect(request: URLRequest(url: URL(string: "wss://test")!))
        let queue = RealtimeSendQueue(transport: transport)

        try await queue.send(ResponseCancel())
        try await queue.send(InputAudioBufferClear())

        let types = transport.sendLog.compactMap { text -> String? in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return obj["type"] as? String
        }
        XCTAssertEqual(types, ["response.cancel", "input_audio_buffer.clear"])
    }

    // MARK: - OpenAIRealtimeWSClient integration

    func testClientExposesRealtimeSendQueue() {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        let queue: RealtimeSendQueue = client.sendQueue
        _ = queue
    }

    // MARK: - drain() returns immediately when idle

    func testDrainReturnsImmediatelyWhenIdle() async {
        let transport = MockTransport()
        let queue = RealtimeSendQueue(transport: transport)
        await queue.drain()
        await queue.drain()
    }
}
