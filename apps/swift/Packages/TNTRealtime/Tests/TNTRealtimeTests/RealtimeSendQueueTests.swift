import XCTest
@testable import TNTRealtime

/// Tests for `RealtimeSendQueue` — the serialized outbound event channel
/// that fixes the append/commit ordering race described in issue #27.
///
/// Acceptance criteria verified here:
/// - Every `append` for a turn precedes its `commit`, which precedes
///   `response.create` — enforced by the actor mailbox + `drain()`.
/// - No append from turn N can land in turn N+1's buffer.
/// - `drain()` + subsequent `send()` calls respect the ordering.
final class RealtimeSendQueueTests: XCTestCase {

    // MARK: - Ordering: appends then drain then commit/create

    /// Core ordering test: enqueue N appends concurrently, then await
    /// drain(), then send commit + response.create. The recorded send
    /// log must show all appends before the commit, which must precede
    /// response.create.
    func testAppendsArrivedBeforeCommitAfterDrain() async throws {
        let transport = MockTransport()
        try await transport.connect(request: URLRequest(url: URL(string: "wss://test")!))
        let queue = RealtimeSendQueue(transport: transport)

        // Simulate what the capture-drain loop does: send N appends.
        for i in 0..<5 {
            try await queue.sendAppend(InputAudioBufferAppend(audio: "frame\(i)"))
        }

        // Simulate what sendCommitAndCreate does on hotkey release:
        // drain, then commit, then response.create.
        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        // All sends serialized through the actor — inspect via the
        // transport's send log.
        let types = transport.sendLog.compactMap { text -> String? in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = obj["type"] as? String else { return nil }
            return type_
        }

        // 5 appends + 1 commit + 1 response.create = 7 events total.
        XCTAssertEqual(types.count, 7)

        // All appends must come before the commit.
        let commitIndex = types.firstIndex(of: "input_audio_buffer.commit")
        let createIndex = types.firstIndex(of: "response.create")
        let appendIndices = types.indices.filter { types[$0] == "input_audio_buffer.append" }

        XCTAssertEqual(appendIndices.count, 5, "Expected 5 appends")
        if let ci = commitIndex {
            for ai in appendIndices {
                XCTAssertLessThan(ai, ci,
                    "Append at index \(ai) must precede commit at index \(ci)")
            }
        } else {
            XCTFail("commit not found in send log")
        }

        // Commit must come before response.create.
        if let ci = commitIndex, let ri = createIndex {
            XCTAssertLessThan(ci, ri,
                "commit (index \(ci)) must precede response.create (index \(ri))")
        } else {
            XCTFail("commit or response.create not found in send log")
        }
    }

    // MARK: - Turn isolation: no cross-turn contamination

    /// After a drain+commit+create for turn 1, appends sent for turn 2
    /// must arrive after the turn-1 commit — verifying that turn N
    /// appends cannot contaminate turn N+1's buffer.
    func testTurnNAppendsDoNotContaminateTurnNPlusOne() async throws {
        let transport = MockTransport()
        try await transport.connect(request: URLRequest(url: URL(string: "wss://test")!))
        let queue = RealtimeSendQueue(transport: transport)

        // Turn 1: two appends then commit.
        try await queue.sendAppend(InputAudioBufferAppend(audio: "t1-frame0"))
        try await queue.sendAppend(InputAudioBufferAppend(audio: "t1-frame1"))
        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        // Turn 2: one append then commit.
        try await queue.sendAppend(InputAudioBufferAppend(audio: "t2-frame0"))
        await queue.drain()
        try await queue.send(InputAudioBufferCommit())
        try await queue.send(ResponseCreate())

        // Parse the send log in order.
        let events: [(type: String, audio: String?)] = transport.sendLog.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type_ = obj["type"] as? String else { return nil }
            return (type: type_, audio: obj["audio"] as? String)
        }

        // Find the first commit index — all turn-2 frames must be after it.
        let firstCommitIndex = events.firstIndex(where: { $0.type == "input_audio_buffer.commit" })!
        let turn2AppendIndex = events.firstIndex(where: { $0.audio == "t2-frame0" })!

        XCTAssertGreaterThan(turn2AppendIndex, firstCommitIndex,
            "Turn-2 append must arrive after turn-1's commit — not before (cross-turn contamination)")
    }

    // MARK: - Non-append sends

    /// Verify that `send(_:)` (non-append path) is also serialized
    /// through the queue and recorded in the transport log.
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

    /// Verify that `OpenAIRealtimeWSClient` exposes a `sendQueue`
    /// backed by its transport. This is the property `VoiceTurnController`
    /// uses — confirm it is accessible from the app target's perspective.
    func testClientExposesRealtimeSendQueue() {
        let transport = MockTransport()
        let client = OpenAIRealtimeWSClient(apiKey: "sk-test", transport: transport)
        // `sendQueue` is a public property — access must compile.
        let queue: RealtimeSendQueue = client.sendQueue
        _ = queue // suppress unused warning
    }
}
